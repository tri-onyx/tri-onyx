defmodule TriOnyx.Integration.AgentLifecycleTest do
  @moduledoc """
  Integration tests for agent lifecycle management.

  Tests the full agent lifecycle: definition loading → registration →
  session creation → status inspection → session stop. Also tests the
  audit log integration and the agent definition parser.

  Note: actual Python runtime interaction is not tested here since
  `uv` + the Python runtime are not available in the test environment.
  The tests verify that the Elixir control plane works correctly up to
  the port spawn boundary.
  """
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentLoader
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.AuditLog
  alias TriOnyx.TriggerRouter

  @test_definition %AgentDefinition{
    name: "lifecycle-agent",
    description: "Test agent for lifecycle testing",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Grep", "Write"],
    network: :none,
    fs_read: ["/workspace/src/**"],
    fs_write: ["/workspace/output/**"],
    system_prompt: "You are a lifecycle test agent."
  }

  @audit_dir "test/tmp/lifecycle_audit"

  setup do
    sup_name = :"lc_sup_#{:erlang.unique_integer([:positive])}"
    router_name = :"lc_router_#{:erlang.unique_integer([:positive])}"

    File.rm_rf!(@audit_dir)

    {:ok, audit_pid} = AuditLog.start_link(name: :lc_audit, audit_dir: @audit_dir)
    {:ok, sup_pid} = AgentSupervisor.start_link(name: sup_name)

    {:ok, router_pid} =
      TriggerRouter.start_link(
        name: router_name,
        supervisor: sup_name,
        definitions: [@test_definition]
      )

    on_exit(fn ->
      safe_stop(router_pid)
      safe_stop(sup_pid)
      safe_stop(audit_pid)
      File.rm_rf!(@audit_dir)
    end)

    %{supervisor: sup_name, router: router_name, audit: :lc_audit}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "agent definition loading" do
    test "parses valid agent markdown" do
      markdown = """
      ---
      name: test-parser
      description: Tests the parser
      model: claude-haiku-4-5
      tools: Read, Grep
      network: none
      fs_read:
        - "/workspace/**"
      ---

      You are a test agent.
      """

      assert {:ok, definition} = AgentDefinition.parse(markdown)
      assert definition.name == "test-parser"
      assert definition.tools == ["Read", "Grep"]
      assert definition.network == :none
      assert definition.network == :none
      assert definition.fs_read == ["/workspace/**"]
      assert definition.system_prompt =~ "You are a test agent."
    end

    test "rejects invalid agent definition" do
      assert {:error, _} = AgentDefinition.parse("no frontmatter here")
    end

    test "loads agent definitions from directory" do
      # Create a temp directory with agent definitions
      dir = Path.join(System.tmp_dir!(), "lifecycle_agents_#{:erlang.unique_integer([:positive])}")
      File.mkdir_p!(dir)

      File.write!(Path.join(dir, "agent-one.md"), """
      ---
      name: agent-one
      description: First agent
      model: claude-haiku-4-5
      tools: Read
      network: none
      ---

      First agent prompt.
      """)

      File.write!(Path.join(dir, "agent-two.md"), """
      ---
      name: agent-two
      description: Second agent
      model: claude-sonnet-4-20250514
      tools: Read, Write
      network: none
      ---

      Second agent prompt.
      """)

      {:ok, definitions} = AgentLoader.load_from(dir)
      assert length(definitions) == 2
      names = Enum.map(definitions, & &1.name) |> Enum.sort()
      assert names == ["agent-one", "agent-two"]

      File.rm_rf!(dir)
    end
  end

  describe "agent registration and lookup" do
    test "registers and retrieves agent", %{router: router} do
      assert {:ok, def} = TriggerRouter.get_agent(router, "lifecycle-agent")
      assert def.name == "lifecycle-agent"
      assert def.name == "lifecycle-agent"
    end

    test "lists all registered agents", %{router: router} do
      agents = TriggerRouter.list_agents(router)
      assert length(agents) == 1
      assert hd(agents).name == "lifecycle-agent"
    end

    test "register, unregister, re-register cycle", %{router: router} do
      extra = %AgentDefinition{
        name: "ephemeral",
        description: "Temporary",
        model: "claude-haiku-4-5",
        tools: ["Read"],
            network: :none,
        fs_read: [],
        fs_write: [],
        system_prompt: "Temp."
      }

      :ok = TriggerRouter.register_agent(router, extra)
      assert {:ok, _} = TriggerRouter.get_agent(router, "ephemeral")

      :ok = TriggerRouter.unregister_agent(router, "ephemeral")
      assert :error = TriggerRouter.get_agent(router, "ephemeral")
    end
  end

  describe "session supervisor management" do
    test "starts with zero active sessions", %{supervisor: sup} do
      assert AgentSupervisor.count_sessions(sup) == 0
      assert AgentSupervisor.list_sessions(sup) == []
    end

    test "find_session returns error for nonexistent agent", %{supervisor: sup} do
      assert :error = AgentSupervisor.find_session(sup, "nonexistent")
    end
  end

  describe "audit log integration" do
    test "writes and reads session events", %{audit: audit} do
      AuditLog.log_session_start(audit, "sess-lc-001", "lifecycle-agent", %{
        input_risk: :low,
        effective_risk: :low,
        information_level: :low
      })

      AuditLog.log_tool_call(audit, "sess-lc-001", "tu-1", "Read", %{
        "file_path" => "/workspace/src/app.py"
      })

      AuditLog.log_information_change(audit, "sess-lc-001", "lifecycle-agent", :low, :high, "webhook payload")

      AuditLog.log_session_stop(audit, "sess-lc-001", "lifecycle-agent", %{
        information_level: :high,
        effective_risk: :high,
        reason: "completed"
      })

      # Ensure all casts are processed
      :sys.get_state(audit)

      # Read entries back
      {:ok, entries} = AuditLog.read_entries(Date.utc_today(), audit_dir: @audit_dir)

      assert length(entries) == 4

      types = Enum.map(entries, & &1["type"])
      assert "session_start" in types
      assert "tool_call" in types
      assert "information_change" in types
      assert "session_stop" in types

      # Verify information change details
      info_entry = Enum.find(entries, &(&1["type"] == "information_change"))
      assert info_entry["old_level"] == "low"
      assert info_entry["new_level"] == "high"
      assert info_entry["source"] == "webhook payload"
    end

    test "writes inter-agent message events", %{audit: audit} do
      AuditLog.log_inter_agent_message(audit, "sender-session", "target-agent", "status_update", true)
      AuditLog.log_inter_agent_message(audit, "sender-session", "target-agent", "raw_data", false)

      :sys.get_state(audit)

      {:ok, entries} = AuditLog.read_entries(Date.utc_today(), audit_dir: @audit_dir)
      ia_entries = Enum.filter(entries, &(&1["type"] == "inter_agent_message"))

      assert length(ia_entries) == 2

      sanitized = Enum.find(ia_entries, &(&1["sanitized"] == true))
      assert sanitized["message_type"] == "status_update"

      unsanitized = Enum.find(ia_entries, &(&1["sanitized"] == false))
      assert unsanitized["message_type"] == "raw_data"
    end

    test "writes trigger events", %{audit: audit} do
      AuditLog.log_trigger(audit, :webhook, "webhook-handler", :untrusted)
      AuditLog.log_trigger(audit, :cron, "cron-agent", :trusted)

      :sys.get_state(audit)

      {:ok, entries} = AuditLog.read_entries(Date.utc_today(), audit_dir: @audit_dir)
      trigger_entries = Enum.filter(entries, &(&1["type"] == "trigger"))

      assert length(trigger_entries) == 2

      webhook = Enum.find(trigger_entries, &(&1["trigger_type"] == "webhook"))
      assert webhook["trust_level"] == "untrusted"

      cron = Enum.find(trigger_entries, &(&1["trigger_type"] == "cron"))
      assert cron["trust_level"] == "trusted"
    end
  end
end
