defmodule TriOnyx.SandboxTest do
  use ExUnit.Case, async: false

  alias TriOnyx.AgentDefinition
  alias TriOnyx.RepoStore
  alias TriOnyx.Sandbox

  @code_reviewer_def """
  ---
  name: code-reviewer
  description: Reviews code for quality issues
  model: claude-sonnet-4-20250514
  tools: Read, Grep, Glob
  network: none
  repos_read:
    - core
  ---

  You are a code reviewer.
  """

  @librarian_def """
  ---
  name: librarian
  tools: Read, Write
  network: none
  repos_read:
    - core
    - agents/news
  repos_write:
    - knowledge
  ---

  You file knowledge.
  """

  @analyzer_def """
  ---
  name: analyzer
  tools: Read
  network: none
  repos_read:
    - agents/*
  ---

  You analyze all agents.
  """

  @webhook_handler_def """
  ---
  name: webhook-handler
  tools: Read, Grep, Glob, Bash, Write, WebFetch
  network:
    - api.github.com
    - hooks.slack.com
  ---

  You handle webhooks.
  """

  @outbound_def """
  ---
  name: outbound-agent
  tools: Read, WebFetch
  network: outbound
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

  @github_def """
  ---
  name: repo-agent
  tools: Read, Write, GitHub
  network: outbound
  github_repo: myorg/myrepo
  github_read_repos:
    - myorg/docs
  ---

  Repo agent.
  """

  @plugin_def """
  ---
  name: news
  tools: Read
  network: outbound
  plugins:
    - newsagg
    - knowledgebase
  repos_write:
    - knowledge
  ---

  News agent.
  """

  setup do
    tmp = Path.join(["test", "tmp", "sandbox_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(tmp)
    original = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, tmp)

    on_exit(fn ->
      Application.put_env(:tri_onyx, :workspace_dir, original)
      File.rm_rf!(tmp)
    end)

    defs =
      for {key, raw} <- [
            code_reviewer: @code_reviewer_def,
            librarian: @librarian_def,
            analyzer: @analyzer_def,
            webhook_handler: @webhook_handler_def,
            outbound_agent: @outbound_def,
            minimal_agent: @minimal_def,
            browser_agent: @browser_def,
            github_agent: @github_def,
            plugin_agent: @plugin_def
          ],
          into: %{} do
        {:ok, definition} = AgentDefinition.parse(raw)
        {key, definition}
      end

    Map.put(defs, :tmp, tmp)
  end

  defp volume_args(args) do
    args
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.filter(fn [flag, _] -> flag == "-v" end)
    |> Enum.map(fn [_, spec] -> spec end)
  end

  describe "build_docker_args/3 basics" do
    test "includes docker run command and base flags", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "sess-001", workspace_dir: "/host/workspace")
      assert hd(args) == "run"
      assert "--rm" in args
      assert "-i" in args
      assert "tri-onyx-code-reviewer-sess-001" in args
      assert List.last(args) == "tri-onyx-agent:latest"
    end

    test "drops all capabilities and never grants SYS_ADMIN or FUSE", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/host/ws")

      assert "--cap-drop" in args
      assert "ALL" in args
      refute "SYS_ADMIN" in args
      refute "--device" in args
      refute "/dev/fuse" in args
      refute Enum.any?(args, &String.starts_with?(&1, "TRI_ONYX_FS_POLICY="))

      # gosu privilege drop still needs these in the root phase
      assert "SETUID" in args
      assert "SETGID" in args
    end
  end

  describe "repo mounts" do
    test "own repo tree is mounted rw at /workspace", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/host/ws")

      assert "/host/ws/trees/minimal-agent/self:/workspace:rw" in volume_args(args)
    end

    test "rw shared clones and ro checkouts mount under /repos", %{librarian: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/host/ws")
      volumes = volume_args(args)

      assert "/host/ws/trees/librarian/self:/workspace:rw" in volumes
      assert "/host/ws/trees/librarian/knowledge:/repos/knowledge:rw" in volumes
      assert "/host/ws/trees/_ro/core:/repos/core:ro" in volumes
      assert "/host/ws/trees/_ro/agents/news:/repos/agents/news:ro" in volumes
    end

    test "agents/* wildcard expands against repos on disk", %{analyzer: def} do
      :ok = RepoStore.ensure_repo({:agent, "news"})
      :ok = RepoStore.ensure_repo({:agent, "wiki"})

      plan = Sandbox.mount_plan(def)
      targets = Enum.map(plan, fn {_host, container, access} -> {container, access} end)

      assert {"/workspace", :rw} in targets
      assert {"/repos/agents/news", :ro} in targets
      assert {"/repos/agents/wiki", :ro} in targets
      # The analyzer's own repo is not mounted twice
      refute {"/repos/agents/analyzer", :ro} in targets
    end

    test "runtime is mounted read-only", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/host/ws")
      assert Enum.any?(volume_args(args), &String.ends_with?(&1, ":/opt/tri_onyx:ro"))
    end
  end

  describe "github mounts" do
    test "clone rw under /github, mirrors ro under /github-ro", %{github_agent: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/host/ws")
      volumes = volume_args(args)

      assert "/host/ws/data/github/myorg/myrepo:/github/myorg/myrepo:rw" in volumes
      assert "/host/ws/data/github-ro/myorg/docs:/github-ro/myorg/docs:ro" in volumes
    end
  end

  describe "network policy" do
    test "none policy uses iptables allowlist env", %{code_reviewer: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/ws")
      assert "TRI_ONYX_NETWORK_POLICY=none" in args
      assert "NET_ADMIN" in args
    end

    test "outbound policy has no NET_ADMIN", %{outbound_agent: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/ws")
      assert "TRI_ONYX_NETWORK_POLICY=outbound" in args
      refute "NET_ADMIN" in args
    end

    test "host allowlist policy", %{webhook_handler: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/ws")
      assert "TRI_ONYX_NETWORK_POLICY=api.github.com,hooks.slack.com" in args
      assert "NET_ADMIN" in args
    end
  end

  describe "browser capability" do
    test "mounts session dir from data/ and sets env", %{browser_agent: def} do
      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/host/ws")

      assert "/host/ws/data/browser-sessions/browser-agent:/home/tri_onyx/.browser-sessions:rw" in volume_args(args)

      assert "TRI_ONYX_BROWSER=true" in args
      assert "CHOWN" in args
    end
  end

  describe "plugin paths" do
    test "resolves owned plugins to /workspace and shared to /repos", %{plugin_agent: def, tmp: tmp} do
      # Owned plugin lives in the agent's own tree; shared one in the
      # agent's knowledge clone.
      File.mkdir_p!(Path.join(tmp, "trees/news/self/plugins/newsagg"))
      File.mkdir_p!(Path.join(tmp, "trees/news/knowledge/plugins/knowledgebase"))

      paths = Sandbox.plugin_paths(def)

      assert paths == %{
               "newsagg" => "/workspace/plugins/newsagg",
               "knowledgebase" => "/repos/knowledge/plugins/knowledgebase"
             }

      args = Sandbox.build_docker_args(def, "s1", workspace_dir: "/host/ws")

      assert "TRI_ONYX_PLUGIN_PATHS=knowledgebase=/repos/knowledge/plugins/knowledgebase,newsagg=/workspace/plugins/newsagg" in args
    end

    test "unresolvable plugins are dropped", %{plugin_agent: def} do
      assert Sandbox.plugin_paths(def) == %{}
    end
  end

  describe "reflection mode" do
    test "mounts session logs read-only", %{minimal_agent: def} do
      args =
        Sandbox.build_docker_args(def, "s1",
          workspace_dir: "/ws",
          mode: :reflection,
          log_dir: "/host/logs"
        )

      assert "/host/logs/minimal-agent:/reflection-logs:ro" in volume_args(args)
      assert "TRI_ONYX_MODE=reflection" in args
    end
  end

  describe "env flags" do
    test "sets agent name and session id", %{minimal_agent: def} do
      args = Sandbox.build_docker_args(def, "sess-42", workspace_dir: "/ws")
      assert "TRI_ONYX_AGENT_NAME=minimal-agent" in args
      assert "TRI_ONYX_SESSION_ID=sess-42" in args
    end
  end
end
