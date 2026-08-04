defmodule TriOnyx.Sandbox do
  @moduledoc """
  Translates agent definitions into Docker container configuration.

  This module is the bridge between the gateway's agent definitions and the
  container runtime. It reads an `AgentDefinition` struct and produces the
  complete set of `docker run` arguments needed to launch a sandboxed agent
  container.

  ## Filesystem: the mount set is the ACL

  There is no in-container filesystem policy engine. Every boundary is a
  git working tree bind-mounted by the kernel:

  - `/workspace` (rw) — the agent's own repo working tree. Always mounted.
  - `/repos/<name>` (rw) — the agent's private clone of each shared repo in
    `repos_write`, synced through the bare repo at session boundaries.
  - `/repos/<name>`, `/repos/agents/<name>` (ro) — the shared `_ro`
    checkout of each repo in `repos_read` (last-committed state).
  - `/github/<owner>/<repo>` (rw) and `/github-ro/<owner>/<repo>` (ro) —
    gateway-owned GitHub clones/mirrors for `github_repo` /
    `github_read_repos`.

  No mounted tree contains git metadata (see `TriOnyx.RepoStore`), so an
  agent can neither read nor rewrite its own history. `RepoStore.prepare_session/1`
  must have run before the container starts so all trees exist and are
  synced.

  ## Network Policy

  - `:none` — iptables allowlist permitting only the Claude API
  - `:outbound` — default Docker networking (unrestricted outbound)
  - host list — default networking + `--cap-add NET_ADMIN` for iptables +
    `TRI_ONYX_NETWORK_POLICY` env var as comma-separated `host[:port]` list
  """

  alias TriOnyx.AgentDefinition
  alias TriOnyx.RepoStore

  @agent_image "tri-onyx-agent:latest"
  @runtime_dir "runtime"

  @doc """
  Builds a list of Docker CLI arguments for `docker run` from an agent
  definition and session ID.

  Returns a list of strings suitable for passing as args to a Port spawning
  `docker`.

  ## Parameters

  - `definition` — an `%AgentDefinition{}` struct
  - `session_id` — a unique string identifying this agent session

  ## Options

  - `:workspace_dir` — HOST path of the workspace root, used as the base
    for all bind mounts (default: current working directory)
  - `:image` — Docker image to use (default: `tri-onyx-agent:latest`)
  - `:mode` — `:normal` (default) or `:reflection`. Reflection mode adds a
    read-only bind mount of the agent's session log directory at
    `/reflection-logs` and sets `TRI_ONYX_MODE=reflection` in the container
    environment so the harness takes the reflection code path.
  - `:log_dir` — host path to the gateway's session log directory (defaults to
    the `:session_log_dir` app env). Only consulted when `mode: :reflection`.
  """
  @spec build_docker_args(AgentDefinition.t(), String.t(), keyword()) :: [String.t()]
  def build_docker_args(%AgentDefinition{} = definition, session_id, opts \\ [])
      when is_binary(session_id) do
    workspace_dir = Keyword.get(opts, :workspace_dir, File.cwd!())
    image = Keyword.get(opts, :image, @agent_image)
    mode = Keyword.get(opts, :mode, :normal)

    ["run"] ++
      base_flags(definition.name, session_id) ++
      cap_flags() ++
      network_flags(definition.network) ++
      repo_mount_flags(definition, workspace_dir) ++
      github_mount_flags(definition, workspace_dir) ++
      runtime_mount_flags() ++
      reflection_flags(definition, mode, opts) ++
      browser_flags(definition, workspace_dir) ++
      docker_socket_flags(definition) ++
      trionyx_repo_flags(definition) ++
      env_flags(definition, session_id, mode) ++
      [image]
  end

  @doc """
  Container mount plan for an agent definition: a list of
  `{host_rel_path, container_path, :rw | :ro}` tuples covering the repo
  trees (host paths relative to the workspace root). Exposed for tests
  and the dashboard.
  """
  @spec mount_plan(AgentDefinition.t()) :: [{String.t(), String.t(), :rw | :ro}]
  def mount_plan(%AgentDefinition{name: name} = definition) do
    %{self: self_repo, write: write, read: read} = RepoStore.grants(definition)

    [{RepoStore.rel_tree_dir(name, self_repo), "/workspace", :rw}] ++
      Enum.map(write, fn repo ->
        {RepoStore.rel_tree_dir(name, repo), "/repos/#{RepoStore.ref(repo)}", :rw}
      end) ++
      Enum.map(read, fn repo ->
        {RepoStore.rel_tree_dir(:ro, repo), "/repos/#{RepoStore.ref(repo)}", :ro}
      end)
  end

  @doc """
  Resolves each declared plugin to its container path.

  A plugin lives inside a repo the agent already mounts: its own repo
  (`/workspace/plugins/<name>`) or a granted shared repo
  (`/repos/<ref>/plugins/<name>`). Resolution checks the gateway-side
  working trees; unresolvable plugins are dropped with a warning.
  """
  @spec plugin_paths(AgentDefinition.t()) :: %{String.t() => String.t()}
  def plugin_paths(%AgentDefinition{plugins: []}), do: %{}

  def plugin_paths(%AgentDefinition{name: name, plugins: plugins} = definition) do
    %{self: self_repo, write: write, read: read} = RepoStore.grants(definition)

    candidates =
      [{name, self_repo, "/workspace"}] ++
        Enum.map(write, fn repo -> {name, repo, "/repos/#{RepoStore.ref(repo)}"} end) ++
        Enum.map(read, fn repo -> {:ro, repo, "/repos/#{RepoStore.ref(repo)}"} end)

    plugins
    |> Enum.flat_map(fn plugin ->
      found =
        Enum.find_value(candidates, fn {principal, repo, container_base} ->
          host_dir = Path.join([RepoStore.tree_dir(principal, repo), "plugins", plugin])
          if File.dir?(host_dir), do: "#{container_base}/plugins/#{plugin}"
        end)

      case found do
        nil ->
          require Logger

          Logger.warning(
            "Sandbox: plugin '#{plugin}' for agent '#{name}' not found in any mounted repo"
          )

          []

        path ->
          [{plugin, path}]
      end
    end)
    |> Map.new()
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

  @spec cap_flags() :: [String.t()]
  defp cap_flags do
    [
      # Drop all capabilities, then add back only what the entrypoint's
      # root phase needs before gosu drops to the tri_onyx user:
      # - SETUID/SETGID: the gosu privilege drop itself
      # - DAC_OVERRIDE: the root phase creates directories inside bind
      #   mounts owned by the host user (e.g. browser output dirs)
      # NET_ADMIN is added separately by network_flags/1 when iptables
      # rules are needed. After gosu, the agent process inherits no
      # capabilities.
      "--cap-drop",
      "ALL",
      "--cap-add",
      "DAC_OVERRIDE",
      "--cap-add",
      "SETUID",
      "--cap-add",
      "SETGID"
    ]
  end

  @spec repo_mount_flags(AgentDefinition.t(), String.t()) :: [String.t()]
  defp repo_mount_flags(definition, workspace_dir) do
    definition
    |> mount_plan()
    |> Enum.flat_map(fn {host_rel, container_path, access} ->
      ["-v", "#{Path.join(workspace_dir, host_rel)}:#{container_path}:#{access}"]
    end)
  end

  # Gateway-owned GitHub clones and mirrors live under the workspace data
  # dir (not repos the gateway manages history for — they have their own
  # upstreams). The rw clone keeps its .git: the GitHub tool needs real
  # git operations inside the container, and the remote is the safety
  # boundary (pushes go through the gateway-held token).
  @spec github_mount_flags(AgentDefinition.t(), String.t()) :: [String.t()]
  defp github_mount_flags(%AgentDefinition{github_repo: repo, github_read_repos: mirrors}, workspace_dir) do
    clone_flags =
      case repo do
        nil ->
          []

        repo ->
          host = Path.join([workspace_dir, "data", "github", repo])
          ["-v", "#{host}:/github/#{repo}:rw"]
      end

    mirror_flags =
      Enum.flat_map(mirrors, fn mirror ->
        host = Path.join([workspace_dir, "data", "github-ro", mirror])
        ["-v", "#{host}:/github-ro/#{mirror}:ro"]
      end)

    clone_flags ++ mirror_flags
  end

  @spec runtime_mount_flags() :: [String.t()]
  defp runtime_mount_flags do
    ["-v", "#{runtime_host_path()}:/opt/tri_onyx:ro"]
  end

  defp runtime_host_path do
    # The gateway runs inside a container where the host repo is mounted at
    # /app. Docker bind mounts are resolved on the host, so translate
    # the container path to its host equivalent when TRI_ONYX_HOST_ROOT is set.
    container_path = Path.expand(@runtime_dir)

    case System.get_env("TRI_ONYX_HOST_ROOT") do
      nil -> container_path
      host_root ->
        case String.trim_trailing(container_path, "/") do
          "/app" <> rest -> Path.join(host_root, rest)
          _ -> container_path
        end
    end
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

  @spec browser_flags(AgentDefinition.t(), String.t()) :: [String.t()]
  defp browser_flags(%AgentDefinition{browser: true, name: name}, workspace_dir) do
    sessions_dir = Path.join([workspace_dir, "data", "browser-sessions", name])

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

  @spec docker_socket_flags(AgentDefinition.t()) :: [String.t()]
  defp docker_socket_flags(%AgentDefinition{docker_socket: true}) do
    # Route through the read-only Docker socket proxy instead of mounting
    # the raw socket. The proxy (tecnativa/docker-socket-proxy) only allows
    # GET requests, blocking exec/run/stop/kill/rm.
    proxy_host = System.get_env("TRI_ONYX_DOCKER_PROXY_HOST", "docker-proxy")
    proxy_port = System.get_env("TRI_ONYX_DOCKER_PROXY_PORT", "2375")
    # The proxy runs on the compose network. Agent containers are spawned
    # via `docker run` and land on the default bridge, so we must connect
    # them to the compose network for DNS resolution of the proxy hostname.
    proxy_network = System.get_env("TRI_ONYX_DOCKER_PROXY_NETWORK", "trionyx_default")

    ["--network", proxy_network, "-e", "DOCKER_HOST=tcp://#{proxy_host}:#{proxy_port}"]
  end

  defp docker_socket_flags(%AgentDefinition{docker_socket: false}), do: []

  @spec trionyx_repo_flags(AgentDefinition.t()) :: [String.t()]
  defp trionyx_repo_flags(%AgentDefinition{trionyx_repo: true}) do
    repo_host_path =
      case System.get_env("TRI_ONYX_HOST_ROOT") do
        nil -> File.cwd!()
        host_root -> host_root
      end

    ["-v", "#{repo_host_path}:/repo:ro"]
  end

  defp trionyx_repo_flags(%AgentDefinition{trionyx_repo: false}), do: []

  @spec reflection_flags(AgentDefinition.t(), :normal | :reflection, keyword()) :: [String.t()]
  defp reflection_flags(_definition, :normal, _opts), do: []

  defp reflection_flags(%AgentDefinition{name: name}, :reflection, opts) do
    log_dir =
      Keyword.get(opts, :log_dir) ||
        Application.get_env(:tri_onyx, :session_log_dir, "logs")

    agent_log_dir = Path.join(Path.expand(log_dir), name)

    ["-v", "#{agent_log_dir}:/reflection-logs:ro"]
  end

  @spec env_flags(AgentDefinition.t(), String.t(), :normal | :reflection) :: [String.t()]
  defp env_flags(%AgentDefinition{} = definition, session_id, mode) do
    # Required env vars
    env = [
      {"-e", "TRI_ONYX_AGENT_NAME=#{definition.name}"},
      {"-e", "TRI_ONYX_SESSION_ID=#{session_id}"}
    ]

    mode_env =
      case mode do
        :reflection -> [{"-e", "TRI_ONYX_MODE=reflection"}]
        :normal -> []
      end

    # Plugin name=container-path pairs for the entrypoint (Python dep
    # install) and the agent runner (plugin loading).
    plugin_env =
      case plugin_paths(definition) do
        empty when map_size(empty) == 0 ->
          []

        paths ->
          encoded =
            paths
            |> Enum.sort()
            |> Enum.map_join(",", fn {plugin, path} -> "#{plugin}=#{path}" end)

          [{"-e", "TRI_ONYX_PLUGIN_PATHS=#{encoded}"}]
      end

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

    (env ++ mode_env ++ plugin_env ++ browser_env ++ passthrough)
    |> Enum.flat_map(fn {flag, value} -> [flag, value] end)
  end
end
