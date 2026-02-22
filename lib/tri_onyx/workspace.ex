defmodule TriOnyx.Workspace do
  @moduledoc """
  Manages the workspace git repository from the gateway side.

  The workspace is a local git repository that stores persistent context
  files (personality, per-agent state, and shared data). The gateway
  initializes the workspace on startup and commits session changes after
  each agent run.

  Workspace layout:

      workspace/
        personality/          — shared personality files
          SOUL.md             — personality, values, tone
          IDENTITY.md         — name, role, capabilities
          USER.md             — user profile and preferences
          MEMORY.md           — long-term memory
        agents/               — per-agent private spaces
          {name}/
            HEARTBEAT.md      — agent-specific state and ongoing work
            memory/
              YYYY-MM-DD.md   — daily memory files
        agent-definitions/    — agent .md files (loaded by AgentLoader)
        AGENTS.md             — agent roster and routing metadata
  """

  require Logger

  @template_files %{
    "personality/SOUL.md" => "# Soul\n\n<!-- Define personality, values, and tone here -->\n",
    "personality/IDENTITY.md" => "# Identity\n\n<!-- Define name, role, and capabilities here -->\n",
    "personality/USER.md" => "# User\n\n<!-- User profile and preferences -->\n",
    "personality/MEMORY.md" => "# Memory\n\n<!-- Long-term memory -->\n",
    "AGENTS.md" => "# Agents\n\n<!-- Agent roster and routing metadata -->\n"
  }

  @doc """
  Returns the configured workspace directory path.
  """
  @spec workspace_dir() :: String.t()
  def workspace_dir do
    Application.get_env(:tri_onyx, :workspace_dir, "./workspace")
  end

  @doc """
  Ensures the workspace directory is initialized as a git repository
  with template context files.

  If the directory already contains a `.git` folder, this is a no-op.
  Otherwise, creates the directory, initializes git, writes template
  files, and creates an initial commit.
  """
  @spec ensure_initialized() :: :ok | {:error, term()}
  def ensure_initialized do
    dir = workspace_dir()

    if File.dir?(Path.join(dir, ".git")) do
      Logger.debug("Workspace already initialized at #{dir}")
      ensure_safe_directory(dir)
      maybe_migrate_layout(dir)
      :ok
    else
      do_initialize(dir)
    end
  end

  @doc """
  Reads a file from the workspace directory.

  The `relative_path` is joined with the workspace directory. Returns
  `{:ok, content}` on success or `{:error, reason}` on failure.
  """
  @spec read_file(String.t()) :: {:ok, String.t()} | {:error, term()}
  def read_file(relative_path) do
    path = Path.join(workspace_dir(), relative_path)

    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Reads all workspace context files and returns a map suitable for
  prompt assembly.

  Returns a map with the following keys:
  - `:soul` — contents of SOUL.md (or nil)
  - `:identity` — contents of IDENTITY.md (or nil)
  - `:user` — contents of USER.md (or nil)
  - `:memory` — contents of MEMORY.md (or nil)
  - `:daily_memory` — contents of memory/YYYY-MM-DD.md for today (or nil)
  - `:heartbeat` — contents of HEARTBEAT.md (or nil)
  """
  @spec read_context(String.t()) :: map()
  def read_context(agent_name) do
    dir = workspace_dir()

    # Read personality files from personality/ subdirectory
    personality_files = %{
      soul: "personality/SOUL.md",
      identity: "personality/IDENTITY.md",
      user: "personality/USER.md",
      memory: "personality/MEMORY.md"
    }

    context =
      personality_files
      |> Enum.map(fn {key, filename} ->
        {key, read_file_or_nil(Path.join(dir, filename))}
      end)
      |> Map.new()

    # Read per-agent heartbeat
    heartbeat_path = Path.join(dir, "agents/#{agent_name}/HEARTBEAT.md")
    context = Map.put(context, :heartbeat, read_file_or_nil(heartbeat_path))

    # Add daily memory for today's date (per-agent)
    today = Date.utc_today() |> Date.to_iso8601()
    daily_path = Path.join(dir, "agents/#{agent_name}/memory/#{today}.md")
    Map.put(context, :daily_memory, read_file_or_nil(daily_path))
  end

  @manifest_path ".tri-onyx/risk-manifest.json"

  @doc """
  Commits modified workspace files after an agent session completes.

  Stages the given paths, checks for actual changes, and commits with
  the agent name and session ID in the commit metadata. When taint/sensitivity
  levels are provided, `Taint-Level` and `Sensitivity-Level` git trailers are
  added to the commit message.

  Returns `{:ok, commit_hash}` if changes were committed, `{:ok, :no_changes}`
  if there were no staged changes, or `{:error, reason}` on failure.
  """
  @spec commit_session(String.t(), String.t(), [String.t()], atom(), atom()) ::
          {:ok, String.t()} | {:ok, :no_changes} | {:error, term()}
  def commit_session(agent_name, session_id, modified_paths, taint_level \\ nil, sensitivity_level \\ nil)
      when is_list(modified_paths) do
    dir = workspace_dir()
    safe = ["-c", "safe.directory=#{Path.expand(dir)}"]

    # Stage the modified files
    add_args = safe ++ ["add", "--" | modified_paths]

    case System.cmd("git", add_args, cd: dir, stderr_to_stdout: true) do
      {_, 0} ->
        # Check if there are actual staged changes
        case System.cmd("git", safe ++ ["diff", "--cached", "--quiet"], cd: dir, stderr_to_stdout: true) do
          {_, 0} ->
            Logger.debug("Workspace: no changes to commit for #{agent_name}/#{session_id}")
            {:ok, :no_changes}

          {_, 1} ->
            # There are staged changes — commit them
            commit_msg = build_commit_message(agent_name, session_id, taint_level, sensitivity_level)
            author = "#{agent_name} <#{agent_name}@tri_onyx>"

            case System.cmd(
                   "git",
                   safe ++ ["commit", "--author=#{author}", "-m", commit_msg],
                   cd: dir,
                   stderr_to_stdout: true,
                   env: committer_env()
                 ) do
              {_, 0} ->
                {hash, 0} =
                  System.cmd("git", safe ++ ["rev-parse", "--short", "HEAD"], cd: dir, stderr_to_stdout: true)

                hash = String.trim(hash)
                Logger.info("Workspace: committed #{hash} for #{agent_name}/#{session_id}")
                {:ok, hash}

              {output, _} ->
                Logger.error("Workspace: git commit failed: #{output}")
                {:error, {:commit_failed, output}}
            end

          {output, code} ->
            Logger.error("Workspace: git diff --cached failed (exit #{code}): #{output}")
            {:error, {:diff_failed, output}}
        end

      {output, _} ->
        Logger.error("Workspace: git add failed: #{output}")
        {:error, {:add_failed, output}}
    end
  end

  @doc """
  Updates the risk manifest with entries for the given paths.

  The manifest lives at `.tri-onyx/risk-manifest.json` in the workspace and
  maps file paths to `%{taint_level, sensitivity_level, risk_level, agent, updated_at}`.
  Existing entries are merged (newer entries overwrite older ones for the same path).

  The `risk_level` field is `max(taint, sensitivity)` for backward compatibility with
  the FUSE driver during migration.

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec update_risk_manifest(String.t(), [String.t()], atom(), atom()) :: :ok | {:error, term()}
  def update_risk_manifest(agent_name, paths, taint_level, sensitivity_level \\ :low) do
    dir = workspace_dir()
    manifest_abs = Path.join(dir, @manifest_path)

    # Ensure .tri-onyx directory exists
    File.mkdir_p!(Path.dirname(manifest_abs))

    # Read existing manifest
    existing = read_risk_manifest()

    # Merge in new entries
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    risk_level = higher_of(taint_level, sensitivity_level)

    updated =
      Enum.reduce(paths, existing, fn path, acc ->
        Map.put(acc, path, %{
          "taint_level" => to_string(taint_level),
          "sensitivity_level" => to_string(sensitivity_level),
          "risk_level" => to_string(risk_level),
          "agent" => agent_name,
          "updated_at" => now
        })
      end)

    # Write back
    case Jason.encode(updated, pretty: true) do
      {:ok, json} ->
        File.write(manifest_abs, json)

      {:error, reason} ->
        Logger.error("Workspace: failed to encode risk manifest: #{inspect(reason)}")
        {:error, {:encode_failed, reason}}
    end
  end

  @doc """
  Reads and parses the risk manifest from the workspace.

  Returns a map of `%{path => %{taint_level, sensitivity_level, risk_level, agent, updated_at}}`,
  or an empty map if the manifest does not exist.
  """
  @spec read_risk_manifest() :: map()
  def read_risk_manifest do
    dir = workspace_dir()
    manifest_abs = Path.join(dir, @manifest_path)

    case File.read(manifest_abs) do
      {:ok, content} ->
        case Jason.decode(content) do
          {:ok, manifest} when is_map(manifest) -> manifest
          _ -> %{}
        end

      {:error, _} ->
        %{}
    end
  end

  @doc """
  Marks the given artifact paths as reviewed by a human.

  Reads the current risk manifest, resets each path's taint to `"low"` but
  leaves sensitivity unchanged, writes the manifest back, and commits the change
  with appropriate trailers.

  Returns `{:ok, paths}` on success or `{:error, reason}` on failure.
  """
  @spec review_artifacts([String.t()], String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def review_artifacts(paths, reviewer) when is_list(paths) and is_binary(reviewer) do
    dir = workspace_dir()
    safe = ["-c", "safe.directory=#{Path.expand(dir)}"]
    manifest_abs = Path.join(dir, @manifest_path)

    # Ensure .tri-onyx directory exists
    File.mkdir_p!(Path.dirname(manifest_abs))

    # Read existing manifest and update reviewed paths
    existing = read_risk_manifest()
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    updated =
      Enum.reduce(paths, existing, fn path, acc ->
        entry = Map.get(acc, path, %{})
        # Reset taint to low, keep sensitivity unchanged
        sensitivity = Map.get(entry, "sensitivity_level", "low")
        risk_level = sensitivity

        Map.put(acc, path, Map.merge(entry, %{
          "taint_level" => "low",
          "sensitivity_level" => sensitivity,
          "risk_level" => risk_level,
          "reviewed_by" => reviewer,
          "reviewed_at" => now
        }))
      end)

    # Write manifest
    case Jason.encode(updated, pretty: true) do
      {:ok, json} ->
        :ok = File.write(manifest_abs, json)

        # Stage and commit
        add_args = safe ++ ["add", @manifest_path]

        case System.cmd("git", add_args, cd: dir, stderr_to_stdout: true) do
          {_, 0} ->
            commit_msg = "review by #{reviewer}\n\nTaint-Level: low"

            case System.cmd(
                   "git",
                   safe ++ ["commit", "-m", commit_msg],
                   cd: dir,
                   stderr_to_stdout: true
                 ) do
              {_, 0} ->
                {:ok, paths}

              {_, 1} ->
                # No changes to commit (manifest unchanged)
                {:ok, paths}

              {output, _} ->
                Logger.error("Workspace: review commit failed: #{output}")
                {:error, {:commit_failed, output}}
            end

          {output, _} ->
            Logger.error("Workspace: review git add failed: #{output}")
            {:error, {:add_failed, output}}
        end

      {:error, reason} ->
        Logger.error("Workspace: failed to encode risk manifest: #{inspect(reason)}")
        {:error, {:encode_failed, reason}}
    end
  end

  @doc """
  Ensures the per-agent directory exists with HEARTBEAT.md and memory/ subdirectory.

  Creates `agents/{name}/` with a template HEARTBEAT.md if it doesn't already
  exist. Idempotent — safe to call on every session start.
  """
  @spec ensure_agent_dir(String.t()) :: :ok
  def ensure_agent_dir(agent_name) do
    dir = workspace_dir()
    agent_dir = Path.join(dir, "agents/#{agent_name}")
    heartbeat_path = Path.join(agent_dir, "HEARTBEAT.md")
    memory_dir = Path.join(agent_dir, "memory")

    File.mkdir_p!(agent_dir)
    File.mkdir_p!(memory_dir)

    unless File.exists?(heartbeat_path) do
      File.write!(heartbeat_path, "# Heartbeat\n\n<!-- Current state and ongoing work -->\n")
    end

    :ok
  end

  # --- Private Helpers ---

  # Detects old workspace layout (SOUL.md at root, no personality/ dir) and
  # migrates files into the new structure.
  @spec maybe_migrate_layout(String.t()) :: :ok
  defp maybe_migrate_layout(dir) do
    old_soul = Path.join(dir, "SOUL.md")
    personality_dir = Path.join(dir, "personality")

    if File.exists?(old_soul) and not File.dir?(personality_dir) do
      Logger.info("Workspace: migrating to per-agent layout")
      safe = ["-c", "safe.directory=#{Path.expand(dir)}"]

      # Create new directories
      File.mkdir_p!(personality_dir)
      File.mkdir_p!(Path.join(dir, "agent-definitions"))
      File.mkdir_p!(Path.join(dir, "agents"))

      # Move personality files
      for file <- ~w(SOUL.md IDENTITY.md USER.md MEMORY.md) do
        src = Path.join(dir, file)
        dst = Path.join(personality_dir, file)

        if File.exists?(src) do
          File.rename!(src, dst)
        end
      end

      # Remove root HEARTBEAT.md (now per-agent)
      heartbeat = Path.join(dir, "HEARTBEAT.md")
      if File.exists?(heartbeat), do: File.rm!(heartbeat)

      # Move old memory/ to personality/legacy-memory/
      old_memory = Path.join(dir, "memory")

      if File.dir?(old_memory) do
        File.rename!(old_memory, Path.join(personality_dir, "legacy-memory"))
      end

      # Commit the migration
      System.cmd("git", safe ++ ["add", "-A"], cd: dir, stderr_to_stdout: true)

      System.cmd(
        "git",
        safe ++ ["commit", "-m", "chore: migrate workspace to per-agent layout"],
        cd: dir,
        stderr_to_stdout: true
      )

      Logger.info("Workspace: migration complete")
    end

    :ok
  end

  @spec build_commit_message(String.t(), String.t(), atom() | nil, atom() | nil) :: String.t()
  defp build_commit_message(agent_name, session_id, nil, _sensitivity_level) do
    "#{agent_name} session #{session_id}"
  end

  defp build_commit_message(agent_name, session_id, taint_level, nil) do
    "#{agent_name} session #{session_id}\n\nTaint-Level: #{taint_level}"
  end

  defp build_commit_message(agent_name, session_id, taint_level, sensitivity_level) do
    "#{agent_name} session #{session_id}\n\nTaint-Level: #{taint_level}\nSensitivity-Level: #{sensitivity_level}"
  end

  @spec higher_of(atom(), atom()) :: atom()
  defp higher_of(a, b) do
    rank = %{low: 0, medium: 1, high: 2}
    if (rank[a] || 0) >= (rank[b] || 0), do: a, else: b
  end

  @spec do_initialize(String.t()) :: :ok | {:error, term()}
  defp do_initialize(dir) do
    Logger.info("Workspace: initializing at #{dir}")

    with :ok <- File.mkdir_p(dir),
         :ok <- File.mkdir_p(Path.join(dir, "personality")),
         :ok <- File.mkdir_p(Path.join(dir, "agent-definitions")),
         :ok <- File.mkdir_p(Path.join(dir, "agents")),
         :ok <- write_template_files(dir),
         {_, 0} <- System.cmd("git", ["init"], cd: dir, stderr_to_stdout: true),
         :ok <- ensure_safe_directory(dir),
         {_, 0} <- System.cmd("git", ["add", "-A"], cd: dir, stderr_to_stdout: true),
         {_, 0} <-
           System.cmd("git", ["commit", "-m", "chore: initialize workspace"],
             cd: dir,
             stderr_to_stdout: true,
             env: committer_env()
           ) do
      Logger.info("Workspace: initialized successfully at #{dir}")
      :ok
    else
      {:error, reason} ->
        Logger.error("Workspace: initialization failed: #{inspect(reason)}")
        {:error, reason}

      {output, code} when is_integer(code) ->
        Logger.error("Workspace: git command failed (exit #{code}): #{output}")
        {:error, {:git_init_failed, output}}
    end
  end

  @spec write_template_files(String.t()) :: :ok | {:error, term()}
  defp write_template_files(dir) do
    Enum.reduce_while(@template_files, :ok, fn {filename, content}, :ok ->
      path = Path.join(dir, filename)
      File.mkdir_p!(Path.dirname(path))

      case File.write(path, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  @spec read_file_or_nil(String.t()) :: String.t() | nil
  defp read_file_or_nil(path) do
    case File.read(path) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  # Marks the workspace directory as safe for git operations regardless of
  # ownership (handles root-owned workspace dirs created inside Docker).
  @spec ensure_safe_directory(String.t()) :: :ok
  defp ensure_safe_directory(dir) do
    abs_dir = Path.expand(dir)

    case System.cmd("git", ["config", "--local", "safe.directory", abs_dir],
           cd: dir,
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {output, code} ->
        Logger.warning("Workspace: failed to set safe.directory (exit #{code}): #{output}")
        :ok
    end
  end

  # Default committer identity for git operations inside Docker where no
  # global git user is configured.
  @spec committer_env() :: [{String.t(), String.t()}]
  defp committer_env do
    [
      {"GIT_COMMITTER_NAME", "TriOnyx"},
      {"GIT_COMMITTER_EMAIL", "gateway@tri_onyx"}
    ]
  end
end
