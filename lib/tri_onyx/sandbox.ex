defmodule TriOnyx.Sandbox do
  @moduledoc """
  Translates agent definitions into Docker container configuration.

  This module is the bridge between the gateway's agent definitions and the
  container runtime. It reads an `AgentDefinition` struct and produces the
  complete set of `docker run` arguments needed to launch a sandboxed agent
  container.

  The sandbox enforces three isolation dimensions:
  - **Filesystem** — FUSE policy JSON passed via environment variable,
    host directory bind-mounted into the container
  - **Network** — Docker network namespace (`none`, default, or allowlisted)
  - **Tools** — passed to the agent runtime via the start protocol message
    (not handled here; see `AgentSession`)

  ## FUSE Policy

  The FUSE driver (`tri-onyx-fs`) inside the container reads a JSON policy
  from the `TRI_ONYX_FS_POLICY` environment variable. This module builds
  that JSON from the `fs_read` and `fs_write` glob patterns in the agent
  definition.

  ## Network Policy

  - `:none` — `--network none` (no network interfaces beyond loopback)
  - `:outbound` — default Docker networking (unrestricted outbound)
  - host list — default networking + `--cap-add NET_ADMIN` for iptables +
    `TRI_ONYX_NETWORK_POLICY` env var as comma-separated `host[:port]` list
  """

  alias TriOnyx.AgentDefinition

  @agent_image "tri-onyx-agent:latest"

  @doc """
  Builds a list of Docker CLI arguments for `docker run` from an agent
  definition and session ID.

  Returns a list of strings suitable for passing as args to a Port spawning
  `docker`.

  ## Parameters

  - `definition` — an `%AgentDefinition{}` struct
  - `session_id` — a unique string identifying this agent session

  ## Options

  - `:workspace_dir` — host workspace directory to bind-mount into the container
    (default: current working directory)
  - `:image` — Docker image to use (default: `tri-onyx-agent:latest`)
  """
  @spec build_docker_args(AgentDefinition.t(), String.t(), keyword()) :: [String.t()]
  def build_docker_args(%AgentDefinition{} = definition, session_id, opts \\ [])
      when is_binary(session_id) do
    workspace_dir = Keyword.get(opts, :workspace_dir, File.cwd!())
    image = Keyword.get(opts, :image, @agent_image)

    ["run"] ++
      base_flags(definition.name, session_id) ++
      fuse_flags() ++
      network_flags(definition.network) ++
      volume_flags(workspace_dir) ++
      browser_flags(definition, workspace_dir) ++
      env_flags(definition, session_id) ++
      [image]
  end

  @doc """
  Builds the FUSE policy JSON string from an agent definition's filesystem
  access patterns.

  The policy format matches what `tri-onyx-fs` expects (see
  `fuse/internal/policy/policy.go` `RawPolicy` struct):

      {
        "fs_read": ["/workspace/repo/src/**/*.py"],
        "fs_write": ["/workspace/repo/src/output/**"],
        "log_denials": true
      }

  Paths in `fs_write` implicitly grant read access (enforced by the FUSE
  driver, not duplicated here).
  """
  @spec build_fuse_policy(AgentDefinition.t()) :: String.t()
  def build_fuse_policy(%AgentDefinition{} = definition) do
    # Inject default per-agent write path
    default_write = "/agents/#{definition.name}/**"
    fs_write = Enum.uniq([default_write | definition.fs_write])

    # Add read paths for each declared skill so the Claude Code CLI can load
    # the SKILL.md files from .claude/skills/<name>/ within the workspace.
    skill_read_paths =
      Enum.map(definition.skills, fn skill ->
        "/workspace/.claude/skills/#{skill}/**"
      end)

    # Add read paths for each declared plugin so the agent can access
    # plugin files from /plugins/<name>/ within the workspace.
    plugin_read_paths =
      Enum.map(definition.plugins, fn plugin ->
        "/plugins/#{plugin}/**"
      end)

    fs_read = Enum.uniq(definition.fs_read ++ skill_read_paths ++ plugin_read_paths)

    policy = %{
      "fs_read" => fs_read,
      "fs_write" => fs_write,
      "log_denials" => true,
      "log_writes" => true,
      "max_read_risk" => Map.get(definition, :max_read_risk, "")
    }

    Jason.encode!(policy)
  end

  # --- Private Helpers ---

  @spec base_flags(String.t(), String.t()) :: [String.t()]
  defp base_flags(agent_name, session_id) do
    [
      "--rm",
      "-i",
      "--name",
      "tri-onyx-#{agent_name}-#{session_id}"
    ]
  end

  @spec fuse_flags() :: [String.t()]
  defp fuse_flags do
    [
      "--device",
      "/dev/fuse",
      # Drop all capabilities first, then add back only what's needed:
      # - SYS_ADMIN: FUSE mount + unshare --mount (to hide /mnt/host)
      # - SETUID/SETGID: gosu privilege drop to tri_onyx user
      # - DAC_OVERRIDE: FUSE daemon runs as root and needs to create/write
      #   files on the host bind mount in directories not owned by root.
      #   Without this, syscall.Open(O_CREAT) fails with EACCES on host
      #   dirs owned by the host user (e.g., uid 1000).
      # NET_ADMIN is added separately by network_flags/1 when iptables
      # rules are needed. After gosu drops to the tri_onyx user, the
      # agent process inherits no capabilities.
      "--cap-drop",
      "ALL",
      "--cap-add",
      "SYS_ADMIN",
      "--cap-add",
      "DAC_OVERRIDE",
      "--cap-add",
      "SETUID",
      "--cap-add",
      "SETGID",
      "--security-opt",
      "apparmor=unconfined"
    ]
  end

  @spec network_flags(AgentDefinition.network_policy()) :: [String.t()]
  defp network_flags(:none) do
    # Use iptables to block all outbound traffic except the Claude API.
    # We cannot use --network none because the agent runtime needs to
    # reach api.anthropic.com for LLM inference.
    [
      "--cap-add",
      "NET_ADMIN",
      "-e",
      "TRI_ONYX_NETWORK_POLICY=none"
    ]
  end

  defp network_flags(:outbound) do
    ["-e", "TRI_ONYX_NETWORK_POLICY=outbound"]
  end

  defp network_flags(hosts) when is_list(hosts) do
    # Host allowlist: use default networking, grant NET_ADMIN for iptables,
    # pass hosts as comma-separated string matching entrypoint.sh format
    network_policy = Enum.join(hosts, ",")

    [
      "--cap-add",
      "NET_ADMIN",
      "-e",
      "TRI_ONYX_NETWORK_POLICY=#{network_policy}"
    ]
  end

  @spec volume_flags(String.t()) :: [String.t()]
  defp volume_flags(workspace_dir) do
    ["-v", "#{workspace_dir}:/mnt/host:rw"]
  end

  @spec browser_flags(AgentDefinition.t(), String.t()) :: [String.t()]
  defp browser_flags(%AgentDefinition{browser: true, name: name}, workspace_dir) do
    sessions_dir = Path.join([workspace_dir, "browser-sessions", name])

    [
      # CHOWN lets the entrypoint chown bind-mounted session files
      # (owned by the host UID) to tri_onyx before dropping privileges.
      # Dropped after gosu — the agent process has no capabilities.
      "--cap-add",
      "CHOWN",
      "-v",
      "#{sessions_dir}:/home/tri_onyx/.browser-sessions:rw"
    ]
  end

  defp browser_flags(%AgentDefinition{browser: false}, _workspace_dir), do: []

  @spec env_flags(AgentDefinition.t(), String.t()) :: [String.t()]
  defp env_flags(%AgentDefinition{} = definition, session_id) do
    fuse_policy = build_fuse_policy(definition)

    # Required env vars
    env = [
      {"-e", "TRI_ONYX_FS_POLICY=#{fuse_policy}"},
      {"-e", "TRI_ONYX_AGENT_NAME=#{definition.name}"},
      {"-e", "TRI_ONYX_SESSION_ID=#{session_id}"}
    ]

    # Browser capability flag
    browser_env =
      if definition.browser do
        [{"-e", "TRI_ONYX_BROWSER=true"}]
      else
        []
      end

    # Pass through host credentials if set
    passthrough =
      ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]
      |> Enum.filter(&System.get_env/1)
      |> Enum.map(fn key -> {"-e", "#{key}=#{System.get_env(key)}"} end)

    (env ++ browser_env ++ passthrough)
    |> Enum.flat_map(fn {flag, value} -> [flag, value] end)
  end
end
