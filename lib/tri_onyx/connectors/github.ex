defmodule TriOnyx.Connectors.GitHub do
  @moduledoc """
  Gateway-side executor for the GitHub tool.

  Holds per-repository fine-grained tokens and executes `gh` / `git`
  commands on behalf of agents. The agent works in a host-side clone
  under `{workspace_dir}/repos/{owner}/{repo}` (visible to it through
  its FUSE mount); only the operations that need credentials — the gh
  CLI and remote git verbs — pass through here. The token never enters
  the agent container.

  Policy classification of commands is owned by
  `TriOnyx.GitHub.CommandPolicy`; this module assumes the caller has
  already obtained an allow/approval verdict.

  ## Configuration

  Tokens come from the `:github` app env (set in `config/runtime.exs`
  from `TRI_ONYX_GITHUB_TOKENS`, a comma-separated list of
  `owner/repo=token` pairs). A `default=token` entry is the fallback for
  repos without an explicit token — note that a shared default trades
  away per-repo blast-radius isolation (any agent using it can act on
  every repo the token can reach):

      config :tri_onyx, :github,
        tokens: %{"owner/repo" => "github_pat_...", "default" => "github_pat_..."},
        bot_name: "TriOnyx Agent",
        bot_email: "tri-onyx@example.invalid"
  """

  require Logger

  # Git credentials are supplied via an inline credential helper reading
  # GH_TOKEN from the environment, so the token never appears in argv
  # (visible in /proc) or in the clone's git config.
  @credential_helper "!f() { echo username=x-access-token; echo password=$GH_TOKEN; }; f"

  @doc """
  Executes a gh or git command for `repo` ("owner/repo").

  Ensures the host-side clone exists first, then runs the command inside
  it with the repo token injected via env. Remote operations are
  serialized per repo so concurrent sessions cannot interleave a fetch
  and a push on the same clone.

  Returns `{:ok, output}` or `{:error, reason}`.
  """
  @spec execute(String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, String.t()}
  def execute(repo, command, args) when command in ["gh", "git"] do
    with {:ok, token} <- token_for(repo) do
      :global.trans({{:tri_onyx_github, repo}, self()}, fn ->
        with {:ok, dir} <- ensure_clone(repo, token) do
          case command do
            "gh" -> run("gh", args, dir, token)
            "git" -> run("git", credential_args() ++ args, dir, token)
          end
        end
      end)
    end
  end

  def execute(_repo, command, _args) do
    {:error, "unsupported command #{inspect(command)}"}
  end

  @doc """
  Returns the configured token for a repo, falling back to the `default`
  entry, or an error if neither is set.
  """
  @spec token_for(String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def token_for(repo) do
    tokens = Keyword.get(config(), :tokens, %{})

    case Map.fetch(tokens, repo) do
      {:ok, token} when is_binary(token) and token != "" ->
        {:ok, token}

      _ ->
        case Map.fetch(tokens, "default") do
          {:ok, token} when is_binary(token) and token != "" ->
            {:ok, token}

          _ ->
            {:error,
             "no GitHub token configured for #{repo} — add it to " <>
               "TRI_ONYX_GITHUB_TOKENS (owner/repo=token,...) or set a default=token entry"}
        end
    end
  end

  @doc """
  Returns the host-side clone directory for a repo.
  """
  @spec repo_dir(String.t()) :: String.t()
  def repo_dir(repo) do
    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    Path.expand(Path.join([workspace_dir, "repos", repo]))
  end

  @doc """
  Ensures the host-side clone for `repo` exists, cloning it if not.

  The clone is configured with `core.symlinks=false` (the FUSE driver
  denies symlinks unconditionally, so git must materialize them as plain
  files) and the bot identity for commits made by the gateway.
  """
  @spec ensure_clone(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure_clone(repo, token) do
    dir = repo_dir(repo)

    if File.dir?(Path.join(dir, ".git")) do
      {:ok, dir}
    else
      clone(repo, token, dir)
    end
  end

  @doc """
  Returns the gateway-owned read-only mirror directory for a repo.
  """
  @spec mirror_dir(String.t()) :: String.t()
  def mirror_dir(repo) do
    workspace_dir = Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
    Path.expand(Path.join([workspace_dir, "repos-ro", repo]))
  end

  @doc """
  Ensures the read-only mirror for `repo` exists and tracks the remote
  default branch.

  Unlike working clones (which agents own and mutate), mirrors belong to
  the gateway: on every call the mirror is force-synced to origin's
  default branch, so a reader always sees current main as of its session
  start. Serialized per repo.
  """
  @spec ensure_mirror(String.t(), String.t()) :: {:ok, String.t()} | {:error, String.t()}
  def ensure_mirror(repo, token) do
    dir = mirror_dir(repo)

    :global.trans({{:tri_onyx_github_mirror, repo}, self()}, fn ->
      if File.dir?(Path.join(dir, ".git")) do
        refresh_mirror(repo, dir, token)
      else
        clone_mirror(repo, token, dir)
      end
    end)
  end

  defp clone_mirror(repo, token, dir) do
    Logger.info("GitHub connector: cloning read-only mirror of #{repo} to #{dir}")
    File.mkdir_p!(Path.dirname(dir))

    args =
      credential_args() ++
        ["clone", "--config", "core.symlinks=false", "https://github.com/#{repo}.git", dir]

    case run_in("git", args, File.cwd!(), token) do
      {_output, 0} -> {:ok, dir}
      {output, code} -> {:error, "mirror clone failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp refresh_mirror(repo, dir, token) do
    with {_out, 0} <- run_in("git", credential_args() ++ ["fetch", "origin"], dir, token),
         # Hard reset is safe here — nothing else writes to the mirror.
         {_out, 0} <- run_in("git", ["reset", "--hard", "origin/HEAD"], dir, token) do
      {:ok, dir}
    else
      {output, code} ->
        Logger.warning(
          "GitHub connector: mirror refresh of #{repo} failed (exit #{code}): " <>
            "#{String.trim(output)} — serving previous state"
        )

        # A stale mirror is still useful context.
        {:ok, dir}
    end
  end

  # --- Private ---

  defp clone(repo, token, dir) do
    Logger.info("GitHub connector: cloning #{repo} to #{dir}")
    File.mkdir_p!(Path.dirname(dir))

    args =
      credential_args() ++
        ["clone", "--config", "core.symlinks=false", "https://github.com/#{repo}.git", dir]

    case run_in("git", args, File.cwd!(), token) do
      {_output, 0} ->
        configure_identity(dir)
        {:ok, dir}

      {output, code} ->
        {:error, "git clone failed (exit #{code}): #{String.trim(output)}"}
    end
  end

  defp configure_identity(dir) do
    bot_name = Keyword.get(config(), :bot_name, "TriOnyx Agent")
    bot_email = Keyword.get(config(), :bot_email, "tri-onyx-agent@users.noreply.github.com")

    System.cmd("git", ["config", "user.name", bot_name], cd: dir)
    System.cmd("git", ["config", "user.email", bot_email], cd: dir)
  end

  defp run(bin, args, dir, token) do
    case run_in(bin, args, dir, token) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:error, "#{bin} exited #{code}: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError ->
      case e do
        %ErlangError{original: :enoent} -> {:error, "#{bin} binary not found on gateway"}
        _ -> {:error, "failed to execute #{bin}: #{Exception.message(e)}"}
      end
  end

  defp run_in(bin, args, dir, token) do
    System.cmd(bin, args,
      cd: dir,
      env: [
        {"GH_TOKEN", token},
        {"GIT_TERMINAL_PROMPT", "0"},
        # gh refuses to use GH_TOKEN when GITHUB_TOKEN is also set differently
        {"GITHUB_TOKEN", token},
        {"GH_PROMPT_DISABLED", "1"},
        {"GH_NO_UPDATE_NOTIFIER", "1"}
      ],
      stderr_to_stdout: true
    )
  end

  defp credential_args do
    # Leading empty helper clears any helpers inherited from system config.
    ["-c", "credential.helper=", "-c", "credential.helper=#{@credential_helper}"]
  end

  defp config do
    case Application.get_env(:tri_onyx, :github) do
      nil -> []
      cfg when is_list(cfg) -> cfg
      cfg when is_map(cfg) -> Map.to_list(cfg)
    end
  end
end
