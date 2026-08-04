defmodule TriOnyx.Workspace do
  @moduledoc """
  Gateway-side façade over the per-agent repo store.

  Historically the workspace was a single shared git repository. It is now
  a collection of git repositories managed by `TriOnyx.RepoStore`: one per
  agent plus shared repos (`core`, `definitions`, ...). This module keeps
  the workspace-level concerns — bootstrap, prompt context assembly,
  session-end commits, canonical path mapping for the risk manifest — and
  delegates all git mechanics to `RepoStore`.

  ## Canonical paths

  The risk manifest and provenance trailers key files by *canonical path*:

      agents/<name>/<path-in-repo>   — file in an agent repo
      shared/<name>/<path-in-repo>   — file in a shared repo

  `canonical_path/2` maps container paths (`/workspace/...`,
  `/repos/...`) to canonical form; `resolve_canonical/1` maps canonical
  form back to `{repo_id, rel_path}`.
  """

  require Logger

  alias TriOnyx.RepoStore

  # Shared repos every installation has. `core` holds AGENTS.md +
  # personality; `definitions` holds the agent definition files the
  # gateway loads.
  @baseline_shared_repos ~w(core definitions)

  @core_templates %{
    "personality/SOUL.md" => "# Soul\n\n<!-- Define personality, values, and tone here -->\n",
    "personality/IDENTITY.md" => "# Identity\n\n<!-- Define name, role, and capabilities here -->\n",
    "personality/USER.md" => "# User\n\n<!-- User profile and preferences -->\n",
    "AGENTS.md" => "# Agents\n\n<!-- Agent roster and routing metadata -->\n"
  }

  @doc """
  Returns the configured workspace directory path (the root under which
  all repos, trees and data live).
  """
  @spec workspace_dir() :: String.t()
  def workspace_dir do
    Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
  end

  @doc """
  Returns the path an agent's own repo tree is mounted at inside agent
  containers. The Python runtime mirrors this as `protocol.WORKSPACE_ROOT`
  (it is also sent as `agent.cwd` in the start message).
  """
  @spec container_root() :: String.t()
  def container_root, do: "/workspace"

  @doc """
  Bootstraps the workspace: directory skeleton plus the baseline shared
  repos (seeding `core` with template files on first run). Idempotent.
  """
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    dir = workspace_dir()

    with :ok <- File.mkdir_p(Path.join(dir, "bare")),
         :ok <- File.mkdir_p(Path.join(dir, "trees")),
         :ok <- File.mkdir_p(Path.join(dir, "gitdirs")),
         :ok <- File.mkdir_p(Path.join(dir, "data")) do
      Enum.each(@baseline_shared_repos, fn name ->
        repo = {:shared, name}
        fresh = not RepoStore.exists?(repo)
        :ok = RepoStore.ensure_repo(repo)
        :ok = RepoStore.ensure_tree(:gw, repo)

        if fresh do
          case name do
            "core" -> seed_core_repo()
            "definitions" -> seed_definitions_repo()
          end
        end

        # Keep a read-only checkout available for prompt assembly and
        # agent ro mounts.
        RepoStore.refresh_ro(repo)
      end)

      :ok
    end
  end

  # Directory holding bootstrap content for fresh installs (personality
  # templates, default agent definitions).
  defp template_dir do
    Application.get_env(:tri_onyx, :workspace_template_dir, "./workspace.template")
  end

  @doc """
  Host path of an agent's own repo working tree (gateway view). This is
  where connectors write inbox items and where the scheduler reads
  HEARTBEAT.md.
  """
  @spec agent_dir(String.t()) :: String.t()
  def agent_dir(agent_name) do
    RepoStore.tree_dir(agent_name, {:agent, agent_name})
  end

  @doc """
  Translates a container path sent by an agent's runtime into a host path
  inside the agent's own working tree.

  Accepts `/workspace/<rest>` (absolute container path) or a bare
  relative path. Returns `{:ok, host_path}` or `{:error, :path_traversal}`
  when the result escapes the agent's tree.
  """
  @spec agent_host_path(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :path_traversal}
  def agent_host_path(agent_name, container_path) do
    rel =
      container_path
      |> String.replace_prefix(container_root() <> "/", "")
      |> String.trim_leading("/")

    base = agent_dir(agent_name) |> Path.expand()
    full = Path.join(base, rel) |> Path.expand()

    if String.starts_with?(full, base <> "/") or full == base do
      {:ok, full}
    else
      {:error, :path_traversal}
    end
  end

  @doc """
  Reads a file from an agent's own working tree. `relative_path` is
  relative to the tree root.
  """
  @spec read_agent_file(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_agent_file(agent_name, relative_path) do
    File.read(Path.join(agent_dir(agent_name), relative_path))
  end

  @doc """
  Reads all workspace context files for prompt assembly.

  Personality files come from the `core` shared repo's read-only checkout
  (last committed state); notes and daily memory come from the agent's
  own working tree.
  """
  @spec read_context(String.t()) :: map()
  def read_context(agent_name) do
    core_tree = RepoStore.tree_dir(:ro, {:shared, "core"})

    context = %{
      soul: read_file_or_nil(Path.join(core_tree, "personality/SOUL.md")),
      identity: read_file_or_nil(Path.join(core_tree, "personality/IDENTITY.md")),
      user: read_file_or_nil(Path.join(core_tree, "personality/USER.md")),
      notes: read_file_or_nil(Path.join(agent_dir(agent_name), "NOTES.md"))
    }

    today = Date.utc_today() |> Date.to_iso8601()
    daily_path = Path.join(agent_dir(agent_name), "memory/#{today}.md")
    Map.put(context, :daily_memory, read_file_or_nil(daily_path))
  end

  @doc """
  Ensures the agent's repo and working tree exist, seeded with
  HEARTBEAT.md and the memory/ directory. Idempotent — safe to call on
  every session start.
  """
  @spec ensure_agent_dir(String.t()) :: :ok
  def ensure_agent_dir(agent_name) do
    :ok = RepoStore.ensure_tree(agent_name, {:agent, agent_name})
    dir = agent_dir(agent_name)
    heartbeat_path = Path.join(dir, "HEARTBEAT.md")

    File.mkdir_p!(Path.join(dir, "memory"))

    unless File.exists?(heartbeat_path) do
      File.write!(heartbeat_path, "# Heartbeat\n\n<!-- Current state and ongoing work -->\n")
    end

    :ok
  end

  @doc """
  Commits an agent session's changes — one commit per rw repo (its own
  plus each `repos_write` grant), pushed to the bare repos.

  Changed paths are recorded in the risk manifest with the session's
  final taint/sensitivity labels before committing, and the commit
  carries `Taint-Level`/`Sensitivity-Level` trailers as the durable
  record.

  Returns `{:ok, results}` with one `{repo_ref, result}` per rw repo.
  """
  @spec commit_session(TriOnyx.AgentDefinition.t(), String.t(), atom() | nil, atom() | nil) ::
          {:ok, [{String.t(), term()}]}
  def commit_session(definition, session_id, taint_level, sensitivity_level) do
    %{self: self_repo, write: write} = RepoStore.grants(definition)

    trailers =
      Enum.reject(
        [
          taint_level && "Taint-Level: #{taint_level}",
          sensitivity_level && "Sensitivity-Level: #{sensitivity_level}"
        ],
        &is_nil/1
      )

    results =
      Enum.map([self_repo | write], fn repo ->
        changed =
          RepoStore.changed_paths(definition.name, repo)
          |> Enum.reject(&temp_file?/1)

        if changed != [] and taint_level != nil do
          canonical = Enum.map(changed, &canonical_for_repo(repo, &1))
          TriOnyx.RiskManifest.put(definition.name, canonical, taint_level, sensitivity_level)
        end

        result =
          if changed == [] and not RepoStore.dirty?(definition.name, repo) do
            {:ok, :no_changes}
          else
            RepoStore.commit_and_push(definition.name, repo,
              author: definition.name,
              message: "#{definition.name} session #{session_id}",
              trailers: trailers,
              session_id: session_id
            )
          end

        case result do
          {:ok, sha} when is_binary(sha) ->
            Logger.info(
              "Workspace: committed #{String.slice(sha, 0, 10)} to #{RepoStore.ref(repo)} " <>
                "for #{definition.name}/#{session_id}"
            )

          {:ok, :no_changes} ->
            :ok

          {:ok, {:conflict, branch}} ->
            Logger.warning(
              "Workspace: session #{session_id} changes to #{RepoStore.ref(repo)} " <>
                "parked on #{branch}"
            )

          {:error, reason} ->
            Logger.error(
              "Workspace: commit failed for #{definition.name}/#{session_id} " <>
                "on #{RepoStore.ref(repo)}: #{inspect(reason)}"
            )
        end

        {RepoStore.ref(repo), result}
      end)

    {:ok, results}
  end

  @doc """
  Commits a single file from an agent's own tree immediately and returns
  the full commit SHA. Used by SubmitPage to pin an HTML artifact to a
  specific version. `path` is relative to the agent's tree (container
  `/workspace/` prefix is stripped if present).
  """
  @spec commit_page(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def commit_page(agent_name, path) do
    rel =
      path
      |> String.replace_prefix(container_root() <> "/", "")
      |> String.trim_leading("/")

    repo = {:agent, agent_name}

    with {:ok, _host} <- agent_host_path(agent_name, rel) do
      case RepoStore.commit_and_push(agent_name, repo,
             author: agent_name,
             message: "#{agent_name} page: #{Path.basename(rel)}",
             session_id: "page",
             paths: [rel]
           ) do
        {:ok, :no_changes} ->
          # Already committed with identical content — return current HEAD.
          case RepoStore.head(repo) do
            {:ok, sha} -> {:ok, sha}
            error -> error
          end

        {:ok, {:conflict, _branch}} = res ->
          res

        other ->
          other
      end
    end
  end

  @doc """
  Records writes made by the gateway itself (connectors polling email,
  calendar, feedback queues) into an agent's tree: updates the risk
  manifest and commits + pushes immediately so provenance is durable and
  readers of the repo see the files.

  `paths` are relative to the agent's tree. `source` names the writer
  (e.g. `"email-connector"`).
  """
  @spec record_external_write(String.t(), String.t(), [String.t()], atom(), atom()) ::
          {:ok, term()} | {:error, term()}
  def record_external_write(agent_name, source, paths, taint, sensitivity) do
    repo = {:agent, agent_name}
    canonical = Enum.map(paths, &canonical_for_repo(repo, &1))
    TriOnyx.RiskManifest.put(agent_name, canonical, taint, sensitivity)

    RepoStore.commit_and_push(agent_name, repo,
      author: source,
      message: "#{source}: deliver to #{agent_name}",
      trailers: ["Taint-Level: #{taint}", "Sensitivity-Level: #{sensitivity}"],
      session_id: "connector",
      paths: paths
    )
  end

  @doc """
  Reads a file at a specific commit from a repo. `repo_ref` is the
  string form (`"agents/<name>"` or a shared repo name).
  """
  @spec read_file_at_commit(String.t(), String.t(), String.t()) ::
          {:ok, binary()} | {:error, term()}
  def read_file_at_commit(repo_ref, commit, path) do
    RepoStore.read_file_at_commit(RepoStore.parse_ref(repo_ref), commit, path)
  end

  @doc """
  Finds `path` at `commit` by scanning every repo. Commit SHAs are
  effectively unique across repos, so the first hit wins. Used by the
  pinned-page endpoint, whose URLs carry only the SHA.
  """
  @spec find_commit_file(String.t(), String.t()) :: {:ok, binary()} | {:error, :not_found}
  def find_commit_file(commit, path) do
    RepoStore.list_repos()
    |> Enum.find_value({:error, :not_found}, fn repo_id ->
      case RepoStore.read_file_at_commit(repo_id, commit, path) do
        {:ok, data} -> {:ok, data}
        {:error, _} -> nil
      end
    end)
  end

  @doc """
  Detects atomic-write temp files created by Claude SDK's Write tool.
  These have patterns like "SOUL.md.tmp.50.1771023878427".
  """
  @spec temp_file?(String.t()) :: boolean()
  def temp_file?(path) do
    basename = Path.basename(path)
    Regex.match?(~r/\.tmp\.\d+\.\d+$/, basename)
  end

  @doc """
  Marks the given artifact paths (canonical form) as reviewed by a human.

  Resets each path's taint to `"low"` in the live risk manifest but leaves
  sensitivity unchanged, then records the review as an empty commit on
  each affected repo carrying one `Reviewed-Path` trailer per path — the
  durable record `TriOnyx.RiskManifest` replays when rebuilding.
  """
  @spec review_artifacts([String.t()], String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def review_artifacts(paths, reviewer) when is_list(paths) and is_binary(reviewer) do
    cond do
      Enum.any?(paths, &(String.contains?(&1, "\n") or &1 == "")) ->
        {:error, :invalid_path}

      Enum.any?(paths, &(resolve_canonical(&1) == :error)) ->
        {:error, :invalid_path}

      true ->
        :ok = TriOnyx.RiskManifest.review(paths, reviewer)

        paths
        |> Enum.group_by(fn path ->
          {:ok, {repo, _rel}} = resolve_canonical(path)
          repo
        end)
        |> Enum.reduce_while({:ok, paths}, fn {repo, repo_paths}, acc ->
          trailers =
            ["Taint-Level: low", "Reviewed-By: #{reviewer}"] ++
              Enum.map(repo_paths, &"Reviewed-Path: #{&1}")

          case RepoStore.empty_commit(repo, reviewer, "review by #{reviewer}", trailers) do
            {:ok, _sha} -> {:cont, acc}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
    end
  end

  @doc """
  Writes an agent definition file through the `definitions` shared repo
  (gateway tree + immediate commit/push, which refreshes the `_ro`
  checkout the loader and watcher consume). Falls back to a plain write
  into the configured agents dir when the definitions repo doesn't exist
  (tests, pre-migration dev setups).
  """
  @spec write_definition(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def write_definition(name, markdown, author \\ "dashboard") do
    repo = {:shared, "definitions"}

    if RepoStore.exists?(repo) do
      with :ok <- RepoStore.sync_tree(:gw, repo) do
        path = Path.join(RepoStore.tree_dir(:gw, repo), "#{name}.md")
        File.write!(path, markdown)

        case RepoStore.commit_and_push(:gw, repo,
               author: author,
               message: "#{author}: update definition #{name}",
               session_id: "definitions",
               paths: ["#{name}.md"]
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    else
      path = Path.join(TriOnyx.agents_dir(), "#{name}.md")
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, markdown)
      :ok
    end
  end

  @doc "Deletes an agent definition file (same routing as `write_definition/3`)."
  @spec delete_definition(String.t(), String.t()) :: :ok | {:error, term()}
  def delete_definition(name, author \\ "dashboard") do
    repo = {:shared, "definitions"}

    if RepoStore.exists?(repo) do
      with :ok <- RepoStore.sync_tree(:gw, repo) do
        path = Path.join(RepoStore.tree_dir(:gw, repo), "#{name}.md")
        File.rm(path)

        case RepoStore.commit_and_push(:gw, repo,
               author: author,
               message: "#{author}: delete definition #{name}",
               session_id: "definitions"
             ) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    else
      File.rm(Path.join(TriOnyx.agents_dir(), "#{name}.md"))
      :ok
    end
  end

  # --- Canonical path mapping ---

  @doc """
  Maps a container path observed for `agent_name` to canonical form.

  `/workspace/<rest>` → `agents/<agent>/<rest>`;
  `/repos/<shared>/<rest>` → `shared/<name>/<rest>`;
  `/repos/agents/<other>/<rest>` → `agents/<other>/<rest>`.
  Relative paths are treated as relative to `/workspace`.
  """
  @spec canonical_path(String.t(), String.t()) :: {:ok, String.t()} | :error
  def canonical_path(agent_name, container_path) do
    case container_path do
      "/workspace/" <> rest -> {:ok, "agents/#{agent_name}/#{rest}"}
      "/repos/agents/" <> rest -> {:ok, "agents/#{rest}"}
      "/repos/" <> rest -> {:ok, "shared/#{rest}"}
      "/" <> _ -> :error
      rel -> {:ok, "agents/#{agent_name}/#{rel}"}
    end
  end

  @doc """
  Resolves a canonical path to `{:ok, {repo_id, rel_path}}` or `:error`.
  """
  @spec resolve_canonical(String.t()) :: {:ok, {RepoStore.repo_id(), String.t()}} | :error
  def resolve_canonical("agents/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [name, rel] when name != "" and rel != "" -> {:ok, {{:agent, name}, rel}}
      _ -> :error
    end
  end

  def resolve_canonical("shared/" <> rest) do
    case String.split(rest, "/", parts: 2) do
      [name, rel] when name != "" and rel != "" -> {:ok, {{:shared, name}, rel}}
      _ -> :error
    end
  end

  def resolve_canonical(_), do: :error

  @doc "Canonical path for a file in a specific repo."
  @spec canonical_for_repo(RepoStore.repo_id(), String.t()) :: String.t()
  def canonical_for_repo({:agent, name}, rel), do: "agents/#{name}/#{rel}"
  def canonical_for_repo({:shared, name}, rel), do: "shared/#{name}/#{rel}"

  # --- Private Helpers ---

  # Seeds the core shared repo with personality files — from
  # workspace.template when present, inline placeholders otherwise.
  defp seed_core_repo do
    tree = RepoStore.tree_dir(:gw, {:shared, "core"})

    Enum.each(@core_templates, fn {filename, fallback} ->
      path = Path.join(tree, filename)
      template = Path.join(template_dir(), filename)
      File.mkdir_p!(Path.dirname(path))

      unless File.exists?(path) do
        case File.read(template) do
          {:ok, content} -> File.write!(path, content)
          {:error, _} -> File.write!(path, fallback)
        end
      end
    end)

    seed_commit({:shared, "core"}, "chore: seed core repo templates")
  end

  # Seeds the definitions shared repo with the default agent definitions
  # from workspace.template (fresh installs only).
  defp seed_definitions_repo do
    tree = RepoStore.tree_dir(:gw, {:shared, "definitions"})
    template = Path.join(template_dir(), "agent-definitions")

    template
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.each(fn file ->
      dest = Path.join(tree, Path.basename(file))
      unless File.exists?(dest), do: File.cp!(file, dest)
    end)

    seed_commit({:shared, "definitions"}, "chore: seed default agent definitions")
  end

  defp seed_commit(repo, message) do
    case RepoStore.commit_and_push(:gw, repo,
           author: "gateway",
           message: message,
           session_id: "bootstrap"
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> Logger.error("Workspace: seed commit failed: #{inspect(reason)}")
    end
  end

  @spec read_file_or_nil(String.t()) :: String.t() | nil
  defp read_file_or_nil(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end
end
