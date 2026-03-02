defmodule TriOnyx.SandboxTest do
  use ExUnit.Case, async: true

  alias TriOnyx.AgentDefinition
  alias TriOnyx.Sandbox

  @code_reviewer_def """
  ---
  name: code-reviewer
  description: Reviews code for quality issues
  model: claude-sonnet-4-20250514
  tools: Read, Grep, Glob
  network: none
  fs_read:
    - "/workspace/repo/src/**/*.py"
    - "/workspace/repo/docs/**/*.md"
  fs_write: []
  ---

  You are a code reviewer.
  """

  @deployer_def """
  ---
  name: deployer
  description: Deploys builds
  model: claude-sonnet-4-20250514
  tools: Read, Grep, Glob, Bash, Write
  network: none
  fs_read:
    - "/workspace/repo/**/*"
  fs_write:
    - "/workspace/repo/deploy/**/*"
    - "/workspace/repo/dist/**/*"
  ---

  You are the deployer.
  """

  @webhook_handler_def """
  ---
  name: webhook-handler
  description: Handles webhooks
  model: claude-haiku-4-5
  tools: Read, Grep, Glob, Bash, Write, WebFetch
  network:
    - api.github.com
    - hooks.slack.com
  fs_read:
    - "/workspace/repo/config/**/*"
  fs_write:
    - "/workspace/repo/data/webhooks/**/*"
  ---

  You handle webhooks.
  """

  @outbound_def """
  ---
  name: outbound-agent
  tools: Read, WebFetch
  network: outbound
  fs_read:
    - "/data/**/*"
  ---

  Outbound agent.
  """

  @minimal_def """
  ---
  name: minimal-agent
  tools: Read
  ---

  Minimal agent.
  """

  @browser_def """
  ---
  name: browser-agent
  tools: Read, Bash
  network: outbound
  browser: true
  ---

  Browser agent.
  """

  setup do
    {:ok, code_reviewer} = AgentDefinition.parse(@code_reviewer_def)
    {:ok, deployer} = AgentDefinition.parse(@deployer_def)
    {:ok, webhook_handler} = AgentDefinition.parse(@webhook_handler_def)
    {:ok, outbound_agent} = AgentDefinition.parse(@outbound_def)
    {:ok, minimal_agent} = AgentDefinition.parse(@minimal_def)
    {:ok, browser_agent} = AgentDefinition.parse(@browser_def)

    %{
      code_reviewer: code_reviewer,
      deployer: deployer,
      webhook_handler: webhook_handler,
      outbound_agent: outbound_agent,
      minimal_agent: minimal_agent,
      browser_agent: browser_agent
    }
  end

  describe "build_docker_args/3" do
    test "includes docker run command", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      assert hd(args) == "run"
    end

    test "includes --rm and -i flags", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      assert "--rm" in args
      assert "-i" in args
    end

    test "does not include -t flag", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      refute "-t" in args
    end

    test "sets container name from agent name and session id", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-abc-123", workspace_dir: "/host/workspace")
      name_idx = Enum.find_index(args, &(&1 == "--name"))
      assert name_idx != nil
      assert Enum.at(args, name_idx + 1) == "tri-onyx-code-reviewer-sess-abc-123"
    end

    test "includes FUSE device and SYS_ADMIN capability", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")

      device_idx = Enum.find_index(args, &(&1 == "--device"))
      assert device_idx != nil
      assert Enum.at(args, device_idx + 1) == "/dev/fuse"

      cap_idx = Enum.find_index(args, &(&1 == "--cap-add"))
      assert cap_idx != nil
      assert Enum.at(args, cap_idx + 1) == "SYS_ADMIN"
    end

    test "drops all capabilities before adding back specific ones", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")

      drop_idx = Enum.find_index(args, &(&1 == "--cap-drop"))
      assert drop_idx != nil
      assert Enum.at(args, drop_idx + 1) == "ALL"

      # --cap-drop ALL must come before --cap-add SYS_ADMIN
      add_idx = Enum.find_index(args, &(&1 == "--cap-add"))
      assert drop_idx < add_idx
    end

    test "uses default image when not specified", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      assert List.last(args) == "tri-onyx-agent:latest"
    end

    test "allows custom image", %{code_reviewer: def} do
      args =
        Sandbox.build_docker_args(def, "sess-001",
          workspace_dir: "/host/workspace",
          image: "my-registry/agent:v2"
        )

      assert List.last(args) == "my-registry/agent:v2"
    end

    # -- Network policy tests --

    test "network :none uses iptables instead of --network none", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      # Should NOT use --network none (agent runtime needs Claude API access)
      refute "--network" in args
      # Should set TRI_ONYX_NETWORK_POLICY=none for entrypoint iptables
      env_values = env_vars_from_args(args)
      assert env_values["TRI_ONYX_NETWORK_POLICY"] == "none"
    end

    test "network :outbound sets TRI_ONYX_NETWORK_POLICY=outbound", %{outbound_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      refute "--network" in args
      env_values = env_vars_from_args(args)
      assert env_values["TRI_ONYX_NETWORK_POLICY"] == "outbound"
    end

    test "network host list sets TRI_ONYX_NETWORK_POLICY as comma-separated string",
         %{webhook_handler: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")

      env_values = env_vars_from_args(args)
      assert Map.has_key?(env_values, "TRI_ONYX_NETWORK_POLICY")

      policy = env_values["TRI_ONYX_NETWORK_POLICY"]
      assert policy == "api.github.com,hooks.slack.com"
    end

    test "network host list adds NET_ADMIN capability for iptables", %{webhook_handler: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")

      # Find all --cap-add values
      caps = cap_add_values(args)
      assert "SYS_ADMIN" in caps
      assert "NET_ADMIN" in caps
    end

    test "network :none adds NET_ADMIN capability for iptables", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")

      caps = cap_add_values(args)
      assert "SYS_ADMIN" in caps
      assert "NET_ADMIN" in caps
    end

    test "network :outbound does not add NET_ADMIN capability", %{outbound_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")

      caps = cap_add_values(args)
      assert "SYS_ADMIN" in caps
      refute "NET_ADMIN" in caps
    end

    test "network host list does not set --network none", %{webhook_handler: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      refute "--network" in args
    end

    # -- Volume mount tests --

    test "mounts workspace volume as :rw", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      volume = find_volume_arg(args)
      assert volume != nil
      assert volume == "/host/workspace:/mnt/host:rw"
    end

    test "always mounts workspace as :rw regardless of fs_write", %{deployer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      volume = find_volume_arg(args)
      assert volume != nil
      assert volume == "/host/workspace:/mnt/host:rw"
    end

    # -- Environment variable tests --

    test "sets TRI_ONYX_FS_POLICY env var with correct keys", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      env_values = env_vars_from_args(args)

      assert Map.has_key?(env_values, "TRI_ONYX_FS_POLICY")
      policy = Jason.decode!(env_values["TRI_ONYX_FS_POLICY"])
      assert policy["fs_read"] == ["/workspace/repo/src/**/*.py", "/workspace/repo/docs/**/*.md"]
      assert policy["fs_write"] == ["/agents/code-reviewer/**"]
      assert policy["log_denials"] == true
      assert policy["log_writes"] == true
    end

    test "sets TRI_ONYX_AGENT_NAME env var", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      env_values = env_vars_from_args(args)
      assert env_values["TRI_ONYX_AGENT_NAME"] == "code-reviewer"
    end

    test "sets TRI_ONYX_SESSION_ID env var", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      env_values = env_vars_from_args(args)
      assert env_values["TRI_ONYX_SESSION_ID"] == "sess-001"
    end

    # -- Minimal agent tests --

    test "minimal agent with no fs patterns produces empty policy", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      env_values = env_vars_from_args(args)

      policy = Jason.decode!(env_values["TRI_ONYX_FS_POLICY"])
      assert policy["fs_read"] == []
      assert policy["fs_write"] == ["/agents/minimal-agent/**"]
      assert policy["log_denials"] == true
    end

    test "minimal agent mounts workspace as :rw", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      volume = find_volume_arg(args)
      assert volume == "/host/workspace:/mnt/host:rw"
    end

    # -- Full integration: deployer --

    test "deployer has correct volume, policy, and network", %{deployer: def} do
      args = Sandbox.build_docker_args(def, "sess-deploy-42", workspace_dir: "/projects/workspace")

      # Workspace always mounted as rw (FUSE enforces access control)
      volume = find_volume_arg(args)
      assert volume == "/projects/workspace:/mnt/host:rw"

      # Network :none uses iptables, not --network none
      refute "--network" in args
      env_values = env_vars_from_args(args)
      assert env_values["TRI_ONYX_NETWORK_POLICY"] == "none"

      # FUSE policy has both read and write patterns
      env_values = env_vars_from_args(args)
      policy = Jason.decode!(env_values["TRI_ONYX_FS_POLICY"])
      assert policy["fs_read"] == ["/workspace/repo/**/*"]
      assert policy["fs_write"] == ["/agents/deployer/**", "/workspace/repo/deploy/**/*", "/workspace/repo/dist/**/*"]
      assert policy["log_denials"] == true

      # Container name
      name_idx = Enum.find_index(args, &(&1 == "--name"))
      assert Enum.at(args, name_idx + 1) == "tri-onyx-deployer-sess-deploy-42"
    end

    # -- Browser capability tests --

    test "browser: true adds browser session volume mount", %{browser_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      volumes = find_all_volume_args(args)

      assert Enum.any?(volumes, fn v ->
        String.contains?(v, "browser-sessions/browser-agent") and
          String.contains?(v, "/home/tri_onyx/.browser-sessions")
      end)
    end

    test "browser: true sets TRI_ONYX_BROWSER env var", %{browser_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      env_values = env_vars_from_args(args)
      assert env_values["TRI_ONYX_BROWSER"] == "true"
    end

    test "browser: false does not add browser volume mount", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      volumes = find_all_volume_args(args)
      refute Enum.any?(volumes, &String.contains?(&1, "browser-sessions"))
    end

    test "browser: false does not set TRI_ONYX_BROWSER env var", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      env_values = env_vars_from_args(args)
      refute Map.has_key?(env_values, "TRI_ONYX_BROWSER")
    end
  end

  describe "build_fuse_policy/1" do
    test "uses fs_read/fs_write keys matching FUSE driver RawPolicy", %{code_reviewer: def} do
      json = Sandbox.build_fuse_policy(def)
      policy = Jason.decode!(json)

      assert is_list(policy["fs_read"])
      assert is_list(policy["fs_write"])
      assert policy["fs_read"] == ["/workspace/repo/src/**/*.py", "/workspace/repo/docs/**/*.md"]
      assert policy["fs_write"] == ["/agents/code-reviewer/**"]
    end

    test "includes write patterns for writable agent", %{deployer: def} do
      json = Sandbox.build_fuse_policy(def)
      policy = Jason.decode!(json)

      assert policy["fs_write"] == ["/agents/deployer/**", "/workspace/repo/deploy/**/*", "/workspace/repo/dist/**/*"]
    end

    test "enables log_denials", %{code_reviewer: def} do
      json = Sandbox.build_fuse_policy(def)
      policy = Jason.decode!(json)

      assert policy["log_denials"] == true
    end

    test "produces valid JSON", %{webhook_handler: def} do
      json = Sandbox.build_fuse_policy(def)
      assert {:ok, _} = Jason.decode(json)
    end

    test "empty definition patterns get default agent write path", %{minimal_agent: def} do
      json = Sandbox.build_fuse_policy(def)
      policy = Jason.decode!(json)

      assert policy["fs_read"] == []
      assert policy["fs_write"] == ["/agents/minimal-agent/**"]
    end
  end

  describe "plugin FUSE path injection" do
    test "auto-injects read paths for declared plugins" do
      content = """
      ---
      name: plugin-agent
      tools: Read
      plugins:
        - newsagg
        - bookmarks
      fs_read:
        - "/AGENTS.md"
      ---

      Plugin agent.
      """

      {:ok, definition} = AgentDefinition.parse(content)
      json = Sandbox.build_fuse_policy(definition)
      policy = Jason.decode!(json)

      assert "/plugins/newsagg/**" in policy["fs_read"]
      assert "/plugins/bookmarks/**" in policy["fs_read"]
      assert "/AGENTS.md" in policy["fs_read"]
    end

    test "does not auto-inject write paths for plugins" do
      content = """
      ---
      name: plugin-agent
      tools: Read
      plugins:
        - diary
      ---

      Plugin agent.
      """

      {:ok, definition} = AgentDefinition.parse(content)
      json = Sandbox.build_fuse_policy(definition)
      policy = Jason.decode!(json)

      refute "/plugins/diary/**" in policy["fs_write"]
    end
  end

  # --- Test Helpers ---

  # Extracts -e KEY=VALUE pairs from docker args into a map
  defp env_vars_from_args(args) do
    args
    |> Enum.chunk_every(2, 1)
    |> Enum.filter(fn
      ["-e", _value] -> true
      _ -> false
    end)
    |> Enum.map(fn ["-e", value] ->
      case String.split(value, "=", parts: 2) do
        [key, val] -> {key, val}
        [key] -> {key, ""}
      end
    end)
    |> Map.new()
  end

  # Extracts all --cap-add values from docker args
  defp cap_add_values(args) do
    args
    |> Enum.chunk_every(2, 1)
    |> Enum.filter(fn
      ["--cap-add", _value] -> true
      _ -> false
    end)
    |> Enum.map(fn ["--cap-add", value] -> value end)
  end

  # Finds the first -v volume argument value
  defp find_volume_arg(args) do
    args
    |> Enum.chunk_every(2, 1)
    |> Enum.find_value(fn
      ["-v", value] -> value
      _ -> nil
    end)
  end

  # Finds all -v volume argument values
  defp find_all_volume_args(args) do
    args
    |> Enum.chunk_every(2, 1)
    |> Enum.filter(fn
      ["-v", _value] -> true
      _ -> false
    end)
    |> Enum.map(fn ["-v", value] -> value end)
  end
end
