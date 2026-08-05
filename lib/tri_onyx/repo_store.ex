defmodule TriOnyx.RepoStore do
  @moduledoc """
  Per-agent git repositories and their managed working trees.

  Every filesystem boundary in TriOnyx is a git repository. Each agent owns
  one repo; shared repos exist per need (`core`, `definitions`, `knowledge`,
  ...). Containers are given plain bind mounts of working trees — there is
  no FUSE layer and no path-glob policy. The mount set is the ACL.

  ## Host layout (under the workspace root)

      workspace/
        bare/
          agents/<name>.git      — bare repo, one per agent (source of truth)
          shared/<name>.git      — bare repo, one per shared repo
        gitdirs/
          <principal>/<repo>.git — git metadata for each working tree
        trees/
          <agent>/self/          — agent's own working tree (mounted rw at /workspace)
          <agent>/<shared>/      — agent's private clone of a shared repo (rw grants)
          _ro/agents/<name>/     — shared read-only checkout of an agent repo
          _ro/<shared>/          — shared read-only checkout of a shared repo
          _gw/<shared>/          — the gateway's own working tree for its writes
        data/                    — non-repo data (browser-sessions, github clones, tmp)

  ## Gateway-only git

  No working tree contains a `.git` entry. All git commands run with
  explicit `--git-dir`/`--work-tree`, so history is unreachable (and
  untamperable) from inside a container that mounts a tree.

  ## Principals

  A *principal* is whoever a working tree belongs to: an agent name, `:ro`
  (the shared read-only checkouts mounted into readers), or `:gw` (the
  gateway's own trees). Read-only grants mount the `_ro` checkout, which is
  refreshed after every push — readers see last-committed state, never
  another agent's in-flight writes.

  ## Sync protocol

  - session start: `sync_tree/2` fast-forwards each rw tree from its bare repo
  - session end: `commit_and_push/3` stages everything, commits with
    provenance trailers, and pushes; a rejected push triggers fetch+merge,
    and an unresolvable conflict is parked on `conflict/<agent>/<session>`
    in the bare repo (nothing is lost, main stays clean)
  """

  require Logger

  @type repo_id :: {:agent, String.t()} | {:shared, String.t()}
  @type principal :: String.t() | :ro | :gw

  @default_branch "main"

  @doc "The branch every repo commits to."
  @spec default_branch() :: String.t()
  def default_branch, do: @default_branch

  # --- Identifiers ---

  @doc """
  Parses a repo reference string from an agent definition into a repo id.

  `"agents/<name>"` refers to an agent repo; any other name is a shared
  repo. The `"agents/*"` wildcard is expanded by `expand_refs/1`.
  """
  @spec parse_ref(String.t()) :: repo_id()
  def parse_ref("agents/" <> name), do: {:agent, name}
  def parse_ref(name) when is_binary(name), do: {:shared, name}

  @doc "String form of a repo id (inverse of `parse_ref/1`)."
  @spec ref(repo_id()) :: String.t()
  def ref({:agent, name}), do: "agents/#{name}"
  def ref({:shared, name}), do: name

  @doc """
  Expands a list of repo reference strings into repo ids, resolving the
  `agents/*` wildcard against the agent repos that exist on disk.
  """
  @spec expand_refs([String.t()]) :: [repo_id()]
  def expand_refs(refs) do
    refs
    |> Enum.flat_map(fn
      "agents/*" -> Enum.map(list_agent_repos(), &{:agent, &1})
      other -> [parse_ref(other)]
    end)
    |> Enum.uniq()
  end

  # --- Grants ---

  @doc """
  Resolves an agent definition's repo grants into concrete repo ids.

  Returns `%{self: repo_id, write: [repo_id], read: [repo_id]}`. The
  agent's own repo never appears in `write`/`read`, and a repo granted rw
  is dropped from the read list. The `agents/*` wildcard expands against
  the agent repos on disk.
  """
  @spec grants(TriOnyx.AgentDefinition.t()) :: %{
          self: repo_id(),
          write: [repo_id()],
          read: [repo_id()]
        }
  def grants(%{name: name, repos_read: repos_read, repos_write: repos_write}) do
    self_repo = {:agent, name}
    write = expand_refs(repos_write) |> List.delete(self_repo)
    read = (expand_refs(repos_read) -- [self_repo | write])

    %{self: self_repo, write: write, read: read}
  end

  @doc """
  Prepares all working trees an agent session will mount.

  Ensures + fast-forwards the agent's own tree and each rw shared-repo
  clone, and refreshes the `_ro` checkout of each read grant. Must run
  before the container starts. Returns the grants map on success.
  """
  @spec prepare_session(TriOnyx.AgentDefinition.t()) ::
          {:ok, map()} | {:error, term()}
  def prepare_session(%{name: name} = definition) do
    %{self: self_repo, write: write, read: read} = g = grants(definition)

    rw_results =
      [self_repo | write]
      |> Enum.map(fn repo_id -> {repo_id, sync_tree(name, repo_id)} end)

    ro_results =
      Enum.map(read, fn repo_id -> {repo_id, refresh_ro(repo_id)} end)

    case Enum.find(rw_results ++ ro_results, fn {_repo, res} -> res != :ok end) do
      nil -> {:ok, g}
      {repo_id, {:error, reason}} -> {:error, {:prepare_failed, ref(repo_id), reason}}
    end
  end

  @doc """
  Commits and pushes every rw tree of an agent session, one commit per
  repo. Returns `{:ok, results}` where results is a list of
  `{repo_ref, commit_result}` tuples.
  """
  @spec commit_session(TriOnyx.AgentDefinition.t(), String.t(), keyword()) ::
          {:ok, [{String.t(), term()}]}
  def commit_session(%{name: name} = definition, session_id, opts \\ []) do
    %{self: self_repo, write: write} = grants(definition)

    results =
      [self_repo | write]
      |> Enum.map(fn repo_id ->
        result =
          commit_and_push(name, repo_id,
            author: name,
            message: "#{name} session #{session_id}",
            trailers: Keyword.get(opts, :trailers, []),
            session_id: session_id
          )

        {ref(repo_id), result}
      end)

    {:ok, results}
  end

  # --- Paths ---

  @doc "The workspace root directory (gateway view)."
  @spec root() :: String.t()
  def root do
    Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
  end

  @doc """
  Working-tree path relative to the workspace root. Used by the sandbox
  to build host-side bind-mount paths (the gateway and the host see the
  workspace at different absolute paths).
  """
  @spec rel_tree_dir(principal(), repo_id()) :: String.t()
  def rel_tree_dir(agent, {:agent, agent}) when is_binary(agent) do
    Path.join(["trees", agent, "self"])
  end

  def rel_tree_dir(principal, repo_id) do
    Path.join(["trees", principal_dir(principal), ref(repo_id)])
  end

  @doc "Path to a repo's bare git directory."
  @spec bare_dir(repo_id()) :: String.t()
  def bare_dir({:agent, name}), do: Path.join([root(), "bare", "agents", name <> ".git"])
  def bare_dir({:shared, name}), do: Path.join([root(), "bare", "shared", name <> ".git"])

  @doc """
  Path to a principal's working tree for a repo.

  An agent's own repo lives at `trees/<agent>/self`; everything else is
  keyed by the repo's reference string.
  """
  @spec tree_dir(principal(), repo_id()) :: String.t()
  def tree_dir(principal, repo_id) do
    Path.join(root(), rel_tree_dir(principal, repo_id))
  end

  @doc "Path to the git metadata directory backing a working tree."
  @spec gitdir(principal(), repo_id()) :: String.t()
  def gitdir(agent, {:agent, agent}) when is_binary(agent) do
    Path.join([root(), "gitdirs", agent, "self.git"])
  end

  def gitdir(principal, repo_id) do
    Path.join([root(), "gitdirs", principal_dir(principal), ref(repo_id) <> ".git"])
  end

  defp principal_dir(:ro), do: "_ro"
  defp principal_dir(:gw), do: "_gw"
  defp principal_dir(agent) when is_binary(agent), do: agent

  @doc "Lists the names of agent repos that exist on disk."
  @spec list_agent_repos() :: [String.t()]
  def list_agent_repos do
    dir = Path.join([root(), "bare", "agents"])

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".git"))
        |> Enum.map(&String.trim_trailing(&1, ".git"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "Lists the names of shared repos that exist on disk."
  @spec list_shared_repos() :: [String.t()]
  def list_shared_repos do
    dir = Path.join([root(), "bare", "shared"])

    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".git"))
        |> Enum.map(&String.trim_trailing(&1, ".git"))
        |> Enum.sort()

      {:error, _} ->
        []
    end
  end

  @doc "Lists all repos that exist on disk."
  @spec list_repos() :: [repo_id()]
  def list_repos do
    Enum.map(list_agent_repos(), &{:agent, &1}) ++
      Enum.map(list_shared_repos(), &{:shared, &1})
  end

  @doc "True if the repo's bare directory exists."
  @spec exists?(repo_id()) :: boolean()
  def exists?(repo_id), do: File.dir?(bare_dir(repo_id))

  # --- Repo lifecycle ---

  @doc """
  Ensures a bare repo exists, creating it with an empty root commit so
  that clones and checkouts work immediately. Idempotent.
  """
  @spec ensure_repo(repo_id()) :: :ok | {:error, term()}
  def ensure_repo(repo_id) do
    bare = bare_dir(repo_id)

    if File.dir?(bare) do
      :ok
    else
      with :ok <- File.mkdir_p(Path.dirname(bare)),
           {_, 0} <- git(["init", "--bare", "-b", @default_branch, bare]),
           {tree, 0} <- git_in(bare, ["hash-object", "-t", "tree", "-w", "/dev/null"]),
           {commit, 0} <-
             git_in(bare, ["commit-tree", String.trim(tree), "-m", "chore: initialize repo"]),
           {_, 0} <-
             git_in(bare, ["update-ref", "refs/heads/#{@default_branch}", String.trim(commit)]) do
        Logger.info("RepoStore: initialized #{ref(repo_id)}")
        :ok
      else
        {:error, reason} -> {:error, reason}
        {output, code} -> {:error, {:git_failed, code, output}}
      end
    end
  end

  @doc """
  Ensures a principal's working tree for a repo exists.

  Creates the bare repo if needed, clones it with a detached git dir, and
  strips the `.git` pointer file so the mounted tree carries no git
  metadata. Idempotent.
  """
  @spec ensure_tree(principal(), repo_id()) :: :ok | {:error, term()}
  def ensure_tree(principal, repo_id) do
    tree = tree_dir(principal, repo_id)
    gd = gitdir(principal, repo_id)

    if File.dir?(gd) and File.dir?(tree) do
      :ok
    else
      locked(repo_id, fn ->
        # Re-check under the lock — another process may have cloned while
        # we were waiting.
        if File.dir?(gd) and File.dir?(tree) do
          :ok
        else
          with :ok <- ensure_repo(repo_id),
               :ok <- File.mkdir_p(Path.dirname(tree)),
               :ok <- File.mkdir_p(Path.dirname(gd)),
               {_, 0} <-
                 git(["clone", "--separate-git-dir", gd, bare_dir(repo_id), tree]),
               :ok <- strip_git_pointer(tree),
               {_, 0} <- git_tree(gd, tree, ["config", "core.fileMode", "false"]),
               {_, 0} <- git_tree(gd, tree, ["config", "core.worktree", Path.expand(tree)]) do
            Logger.info("RepoStore: created tree #{principal_dir(principal)}/#{ref(repo_id)}")
            :ok
          else
            {:error, reason} -> {:error, reason}
            {output, code} -> {:error, {:git_failed, code, output}}
          end
        end
      end)
    end
  end

  @doc """
  Fast-forwards a working tree to the bare repo's current branch tip.

  Untracked files in the tree (e.g. gateway-written inbox items awaiting
  their session) are preserved. Falls back to a merge when the tree's
  branch has local commits (shouldn't happen in normal operation).
  """
  @spec sync_tree(principal(), repo_id()) :: :ok | {:error, term()}
  def sync_tree(principal, repo_id) do
    with :ok <- ensure_tree(principal, repo_id) do
      gd = gitdir(principal, repo_id)
      tree = tree_dir(principal, repo_id)

      result =
        locked(repo_id, fn ->
          with {_, 0} <- git_tree(gd, tree, ["fetch", "origin"]),
               {_, 0} <-
                 git_tree(gd, tree, ["merge", "--ff-only", "origin/#{@default_branch}"]) do
            :ok
          else
            {output, code} ->
              Logger.warning(
                "RepoStore: ff sync failed for #{principal_dir(principal)}/#{ref(repo_id)} " <>
                  "(exit #{code}): #{String.slice(output, 0, 500)} — attempting merge"
              )

              case git_tree(gd, tree, ["merge", "--no-edit", "origin/#{@default_branch}"]) do
                {_, 0} -> :ok
                {out, c} -> {:error, {:sync_failed, c, out}}
              end
          end
        end)

      with :ok <- result, do: chown_tree(principal, repo_id)
    end
  end

  @doc """
  Refreshes the shared read-only checkout of a repo to the bare tip.

  Unlike `sync_tree/2` this discards any local state — the `_ro` tree is a
  pure projection of the last commit and nothing else ever writes to it.
  """
  @spec refresh_ro(repo_id()) :: :ok | {:error, term()}
  def refresh_ro(repo_id) do
    with :ok <- ensure_tree(:ro, repo_id) do
      gd = gitdir(:ro, repo_id)
      tree = tree_dir(:ro, repo_id)

      locked(repo_id, fn ->
        with {_, 0} <- git_tree(gd, tree, ["fetch", "origin"]),
             {_, 0} <- git_tree(gd, tree, ["reset", "--hard", "origin/#{@default_branch}"]),
             {_, 0} <- git_tree(gd, tree, ["clean", "-fd"]) do
          :ok
        else
          {output, code} -> {:error, {:refresh_failed, code, output}}
        end
      end)
    end
  end

  @doc """
  Commits all changes in a principal's working tree and pushes to the
  bare repo, then refreshes the shared read-only checkout.

  ## Options

  - `:author` — commit author name (defaults to the principal)
  - `:message` — commit subject line (required)
  - `:trailers` — list of `"Key: value"` git trailer strings
  - `:session_id` — used to name the conflict branch when a merge fails
  - `:paths` — stage only these tree-relative paths instead of everything
    (paths that no longer exist on disk are skipped)

  Returns `{:ok, sha}`, `{:ok, :no_changes}`, `{:ok, {:conflict, branch}}`
  when the commit was parked on a conflict branch, or `{:error, reason}`.
  """
  @spec commit_and_push(principal(), repo_id(), keyword()) ::
          {:ok, String.t()} | {:ok, :no_changes} | {:ok, {:conflict, String.t()}} | {:error, term()}
  def commit_and_push(principal, repo_id, opts) do
    with :ok <- ensure_tree(principal, repo_id) do
      gd = gitdir(principal, repo_id)
      tree = tree_dir(principal, repo_id)
      author_name = Keyword.get(opts, :author, principal_dir(principal))
      message = Keyword.fetch!(opts, :message)
      trailers = Keyword.get(opts, :trailers, [])
      session_id = Keyword.get(opts, :session_id, "manual")

      # `git add -- <path>` fails outright if any pathspec matches nothing
      # (e.g. a file created then deleted mid-session), so filter first.
      add_args =
        case Keyword.get(opts, :paths) do
          nil ->
            ["add", "-A"]

          paths ->
            existing = Enum.filter(paths, &File.exists?(Path.join(tree, &1)))
            ["add", "--" | existing]
        end

      commit_msg =
        case trailers do
          [] -> message
          _ -> message <> "\n\n" <> Enum.join(trailers, "\n")
        end

      locked(repo_id, fn ->
        with {_, 0} <- stage(gd, tree, add_args),
             {:changes, true} <- {:changes, staged_changes?(gd, tree)},
             {_, 0} <-
               git_tree(
                 gd,
                 tree,
                 ["commit", "--author=#{author_name} <#{author_name}@tri_onyx>", "-m", commit_msg]
               ),
             {sha, 0} <- git_tree(gd, tree, ["rev-parse", "HEAD"]) do
          sha = String.trim(sha)

          case push(gd, tree, principal, repo_id, session_id) do
            :ok ->
              do_refresh_ro(repo_id)
              {:ok, sha}

            {:conflict, branch} ->
              {:ok, {:conflict, branch}}

            {:error, reason} ->
              {:error, reason}
          end
        else
          {:changes, false} -> {:ok, :no_changes}
          {output, code} -> {:error, {:git_failed, code, output}}
        end
      end)
    end
  end

  @doc "All file paths at a repo's HEAD (committed view)."
  @spec ls_tree(repo_id()) :: {:ok, [String.t()]} | {:error, term()}
  def ls_tree(repo_id) do
    case git_in(bare_dir(repo_id), ["ls-tree", "-r", "--name-only", "-z", @default_branch]) do
      {out, 0} -> {:ok, String.split(out, <<0>>, trim: true)}
      {out, code} -> {:error, {:git_failed, code, out}}
    end
  end

  @doc "Current HEAD commit SHA of a repo's bare dir."
  @spec head(repo_id()) :: {:ok, String.t()} | {:error, term()}
  def head(repo_id) do
    case git_in(bare_dir(repo_id), ["rev-parse", @default_branch]) do
      {sha, 0} -> {:ok, String.trim(sha)}
      {out, code} -> {:error, {:git_failed, code, out}}
    end
  end

  @doc "True if a principal's working tree has uncommitted changes."
  @spec dirty?(principal(), repo_id()) :: boolean()
  def dirty?(principal, repo_id) do
    gd = gitdir(principal, repo_id)
    tree = tree_dir(principal, repo_id)

    if File.dir?(gd) and File.dir?(tree) do
      case git_tree(gd, tree, ["status", "--porcelain"]) do
        {"", 0} -> false
        {_out, 0} -> true
        _ -> false
      end
    else
      false
    end
  end

  @doc "Paths changed (relative to the tree root) in a principal's working tree."
  @spec changed_paths(principal(), repo_id()) :: [String.t()]
  def changed_paths(principal, repo_id) do
    gd = gitdir(principal, repo_id)
    tree = tree_dir(principal, repo_id)

    case git_tree(gd, tree, ["status", "--porcelain", "-z", "-uall"]) do
      {out, 0} ->
        out
        |> String.split(<<0>>, trim: true)
        |> parse_status_entries([])

      _ ->
        []
    end
  end

  # In `status --porcelain -z` output, rename/copy entries emit the origin
  # path as an extra NUL-separated field after "XY newpath" — skip it.
  defp parse_status_entries([], acc), do: Enum.reverse(acc)

  defp parse_status_entries([entry | rest], acc) do
    status = String.slice(entry, 0, 2)
    path = String.slice(entry, 3..-1//1)

    rest =
      if String.contains?(status, "R") or String.contains?(status, "C") do
        tl(rest)
      else
        rest
      end

    if path in [nil, ""] do
      parse_status_entries(rest, acc)
    else
      parse_status_entries(rest, [path | acc])
    end
  end

  @doc "Reads a file from a repo at a specific commit (`git show sha:path`)."
  @spec read_file_at_commit(repo_id(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def read_file_at_commit(repo_id, commit, path) do
    if Regex.match?(~r/\A[0-9a-f]{7,40}\z/, commit) do
      case git_in(bare_dir(repo_id), ["show", "#{commit}:#{path}"]) do
        {content, 0} -> {:ok, content}
        {_out, _} -> {:error, :not_found}
      end
    else
      {:error, :invalid_commit}
    end
  end

  @doc """
  Records an empty commit on a repo (e.g. human review events that carry
  only trailers). Goes through the gateway's `_gw` tree.
  """
  @spec empty_commit(repo_id(), String.t(), String.t(), [String.t()]) ::
          {:ok, String.t()} | {:error, term()}
  def empty_commit(repo_id, author_name, message, trailers) do
    with :ok <- ensure_tree(:gw, repo_id),
         :ok <- sync_tree(:gw, repo_id) do
      gd = gitdir(:gw, repo_id)
      tree = tree_dir(:gw, repo_id)
      commit_msg = message <> "\n\n" <> Enum.join(trailers, "\n")

      locked(repo_id, fn ->
        with {_, 0} <-
               git_tree(gd, tree, [
                 "commit",
                 "--allow-empty",
                 "--author=#{author_name} <#{author_name}@tri_onyx>",
                 "-m",
                 commit_msg
               ]),
             {sha, 0} <- git_tree(gd, tree, ["rev-parse", "HEAD"]),
             :ok <- push(gd, tree, :gw, repo_id, "review") |> normalize_push() do
          {:ok, String.trim(sha)}
        else
          {:error, reason} -> {:error, reason}
          {output, code} when is_integer(code) -> {:error, {:git_failed, code, output}}
        end
      end)
    end
  end

  @doc """
  Runs `git log` on a repo's bare dir with the given extra args.
  Used by RiskManifest replay and provenance queries.
  """
  @spec log(repo_id(), [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def log(repo_id, args) do
    case git_in(bare_dir(repo_id), ["log" | args]) do
      {out, 0} -> {:ok, out}
      {out, code} -> {:error, {:git_failed, code, out}}
    end
  end

  # --- Private ---

  defp normalize_push(:ok), do: :ok
  defp normalize_push({:conflict, branch}), do: {:error, {:conflict, branch}}
  defp normalize_push({:error, reason}), do: {:error, reason}

  # Push HEAD to the bare repo's main branch. On a non-fast-forward
  # rejection (another principal pushed first), fetch and merge, then retry
  # once. If the merge conflicts, park the commit on a conflict branch and
  # reset the tree back to origin — nothing is lost, main stays clean.
  defp push(gd, tree, principal, repo_id, session_id) do
    case git_tree(gd, tree, ["push", "origin", @default_branch]) do
      {_, 0} ->
        :ok

      {_output, _} ->
        with {_, 0} <- git_tree(gd, tree, ["fetch", "origin"]),
             {_, 0} <- git_tree(gd, tree, ["merge", "--no-edit", "origin/#{@default_branch}"]),
             {_, 0} <- git_tree(gd, tree, ["push", "origin", @default_branch]) do
          :ok
        else
          _ ->
            park_conflict(gd, tree, principal, repo_id, session_id)
        end
    end
  end

  defp park_conflict(gd, tree, principal, repo_id, session_id) do
    branch = "conflict/#{principal_dir(principal)}/#{session_id}"

    # Abort any in-progress merge, then push the local commit as-is to a
    # conflict branch and hard-reset the tree onto origin/main.
    _ = git_tree(gd, tree, ["merge", "--abort"])

    with {_, 0} <- git_tree(gd, tree, ["push", "-f", "origin", "HEAD:refs/heads/#{branch}"]),
         {_, 0} <- git_tree(gd, tree, ["fetch", "origin"]),
         {_, 0} <- git_tree(gd, tree, ["reset", "--hard", "origin/#{@default_branch}"]) do
      Logger.warning(
        "RepoStore: push conflict on #{ref(repo_id)} — parked on #{branch}"
      )

      {:conflict, branch}
    else
      {output, code} -> {:error, {:conflict_park_failed, code, output}}
    end
  end

  # Working trees are checked out by the gateway user (root in the gateway
  # container) but mounted rw into agent containers running as the host
  # user, so every git write (clone, fetch/merge, reset) leaves files the
  # agent cannot modify. Hand ownership to the configured agent uid after
  # every sync. Only agent trees need this — `_ro` mounts are read-only and
  # `_gw` trees never leave the gateway. A failed chown fails the session
  # prep loudly; the alternative is the agent hitting bare EACCES mid-run.
  defp chown_tree(principal, repo_id) when is_binary(principal) do
    case tree_owner() do
      nil ->
        :ok

      {uid, gid} ->
        tree = tree_dir(principal, repo_id)

        case System.cmd("chown", ["-R", "#{uid}:#{gid}", tree], stderr_to_stdout: true) do
          {_, 0} -> :ok
          {out, code} -> {:error, {:chown_failed, code, String.slice(out, 0, 500)}}
        end
    end
  end

  defp chown_tree(_principal, _repo_id), do: :ok

  defp tree_owner do
    case Application.get_env(:tri_onyx, :tree_owner_uid) do
      uid when is_binary(uid) and uid != "" ->
        {uid, Application.get_env(:tri_onyx, :tree_owner_gid) || uid}

      _ ->
        nil
    end
  end

  # `git add` with an empty explicit pathspec list is a no-op, not an
  # error — model it as a successful command with nothing staged.
  defp stage(_gd, _tree, ["add", "--"]), do: {"", 0}
  defp stage(gd, tree, add_args), do: git_tree(gd, tree, add_args)

  defp staged_changes?(gd, tree) do
    case git_tree(gd, tree, ["diff", "--cached", "--quiet"]) do
      {_, 0} -> false
      {_, 1} -> true
      # On error, err on the side of attempting the commit
      _ -> true
    end
  end

  # Removes the `.git` pointer file `git clone --separate-git-dir` leaves
  # in the working tree. All subsequent git operations pass the git dir
  # explicitly, so the tree stays free of git metadata.
  defp strip_git_pointer(tree) do
    pointer = Path.join(tree, ".git")

    case File.rm(pointer) do
      :ok -> :ok
      {:error, :enoent} -> :ok
      {:error, reason} -> {:error, {:git_pointer, reason}}
    end
  end

  # Serializes mutating operations per bare repo across the node. Pushes
  # from different principals to the same repo are cheap, so a coarse
  # global transaction is fine.
  defp locked(repo_id, fun) do
    :global.trans({{:tri_onyx_repo, ref(repo_id)}, self()}, fun, [Node.self()])
  end

  # Refresh the shared read-only checkout after a push. Failures are
  # logged, not propagated — the commit itself already succeeded, and the
  # next push (or refresh_ro call) will bring _ro back in sync.
  # :global locks are re-entrant per {key, pid}, so calling this from
  # inside a locked/2 block is safe.
  defp do_refresh_ro(repo_id) do
    case refresh_ro(repo_id) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("RepoStore: _ro refresh failed for #{ref(repo_id)}: #{inspect(reason)}")
        :ok
    end
  end

  # git in a bare dir (no work tree)
  defp git_in(git_dir, args) do
    run_git(["--git-dir", git_dir | args])
  end

  # git against an explicit gitdir + work tree
  defp git_tree(git_dir, tree, args) do
    run_git(["--git-dir", git_dir, "--work-tree", tree | args])
  end

  # bare `git` for commands that take paths as args (init/clone)
  defp git(args), do: run_git(args)

  defp run_git(args) do
    safe = ["-c", "safe.directory=*"]
    System.cmd("git", safe ++ args, stderr_to_stdout: true, env: committer_env())
  end

  defp committer_env do
    [
      {"GIT_COMMITTER_NAME", "TriOnyx"},
      {"GIT_COMMITTER_EMAIL", "gateway@tri_onyx"},
      {"GIT_AUTHOR_NAME", "TriOnyx"},
      {"GIT_AUTHOR_EMAIL", "gateway@tri_onyx"}
    ]
  end
end
