defmodule TriOnyx.SystemCommandTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.SystemCommand
  alias TriOnyx.TriggerRouter

  @test_definition %AgentDefinition{
    name: "test-agent",
    description: "A test agent",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    system_prompt: "You are a test agent."
  }

  @channel_definition %AgentDefinition{
    name: "channel-agent",
    description: "The agent a connector channel is bound to",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    system_prompt: "You are the channel's own agent.",
    restart_targets: ["allowed-target"]
  }

  @other_definition %AgentDefinition{
    name: "allowed-target",
    description: "An agent the channel agent is allowed to restart",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    system_prompt: "You are an allowed restart target."
  }

  @victim_definition %AgentDefinition{
    name: "victim-agent",
    description: "An agent the channel agent is NOT allowed to restart",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    system_prompt: "You are an unrelated agent."
  }

  # --- parse/1 tests ---

  describe "parse/1" do
    test "parses /restart with agent name" do
      assert {:command, :restart, ["researcher"]} = SystemCommand.parse("/restart researcher")
    end

    test "parses /restart without agent name" do
      assert {:command, :restart, []} = SystemCommand.parse("/restart")
    end

    test "parses /restart with extra whitespace" do
      assert {:command, :restart, ["researcher"]} = SystemCommand.parse("/restart   researcher")
    end

    test "returns unknown for unrecognized command" do
      assert {:command, :unknown, ["/foo"]} = SystemCommand.parse("/foo")
    end

    test "returns unknown for bare slash" do
      assert {:command, :unknown, ["/"]} = SystemCommand.parse("/")
    end

    test "returns not_a_command for regular messages" do
      assert :not_a_command = SystemCommand.parse("hello world")
    end

    test "returns not_a_command for empty string" do
      assert :not_a_command = SystemCommand.parse("")
    end

    test "returns not_a_command for slash in the middle" do
      assert :not_a_command = SystemCommand.parse("hello /restart")
    end
  end

  # --- execute/3 tests ---

  describe "execute(:restart, ...)" do
    setup do
      sup_name = :"test_sup_#{:erlang.unique_integer([:positive])}"
      router_name = :"test_router_#{:erlang.unique_integer([:positive])}"

      {:ok, sup_pid} = AgentSupervisor.start_link(name: sup_name)

      {:ok, router_pid} =
        TriggerRouter.start_link(
          name: router_name,
          supervisor: sup_name,
          definitions: [
            @test_definition,
            @channel_definition,
            @other_definition,
            @victim_definition
          ]
        )

      on_exit(fn ->
        safe_stop(router_pid)
        safe_stop(sup_pid)
      end)

      %{sup_name: sup_name, router_name: router_name}
    end

    test "returns error when agent not found", %{router_name: router, sup_name: sup} do
      assert {:error, "Unknown agent 'nonexistent'"} =
               SystemCommand.execute(:restart, ["nonexistent"], %{}, router: router, supervisor: sup)
    end

    test "starts agent that is not running", %{router_name: router, sup_name: sup} do
      assert :error = AgentSupervisor.find_session(sup, "test-agent")

      assert {:ok, msg} =
               SystemCommand.execute(:restart, ["test-agent"], %{}, router: router, supervisor: sup)

      assert msg =~ "was not running"
    end

    test "returns error when no agent name specified" do
      assert {:error, "No agent specified"} =
               SystemCommand.execute(:restart, [], %{})
    end

    test "uses context agent_name when no args given", %{router_name: router, sup_name: sup} do
      assert {:ok, msg} =
               SystemCommand.execute(:restart, [], %{agent_name: "test-agent"},
                 router: router,
                 supervisor: sup
               )

      assert msg =~ "was not running"
    end

    test "force restart starts agent that is not running", %{router_name: router, sup_name: sup} do
      assert :error = AgentSupervisor.find_session(sup, "test-agent")

      assert {:ok, msg} =
               SystemCommand.execute(:restart, ["test-agent"], %{},
                 router: router,
                 supervisor: sup,
                 force: true
               )

      assert msg =~ "was not running"
    end

    test "a connector channel may always restart its own agent", %{
      router_name: router,
      sup_name: sup
    } do
      assert {:ok, msg} =
               SystemCommand.execute(:restart, ["channel-agent"], %{agent_name: "channel-agent"},
                 router: router,
                 supervisor: sup
               )

      assert msg =~ "was not running"
    end

    test "a connector channel may restart a declared restart_target", %{
      router_name: router,
      sup_name: sup
    } do
      assert {:ok, msg} =
               SystemCommand.execute(
                 :restart,
                 ["allowed-target"],
                 %{agent_name: "channel-agent"},
                 router: router,
                 supervisor: sup
               )

      assert msg =~ "was not running"
    end

    test "a connector channel cannot restart an agent outside its restart_targets", %{
      router_name: router,
      sup_name: sup
    } do
      # A message arriving through the channel bound to 'channel-agent' must
      # not be able to interrupt an unrelated agent it was never authorized
      # for — the same rule AgentSession enforces via `restart_targets` for
      # agent-initiated restarts (lib/tri_onyx/agent_session.ex) must also
      # hold for connector-initiated ones (lib/tri_onyx/connector_handler.ex),
      # which call this same function with `context: %{agent_name: <channel's
      # own agent>}`.
      assert {:error, message} =
               SystemCommand.execute(
                 :restart,
                 ["victim-agent"],
                 %{agent_name: "channel-agent"},
                 router: router,
                 supervisor: sup
               )

      assert message =~ "not reachable from this context"

      # And, crucially, the victim was never touched.
      assert :error = AgentSupervisor.find_session(sup, "victim-agent")
    end

    test "a call with no session context (agent-to-agent restart) is unaffected", %{
      router_name: router,
      sup_name: sup
    } do
      # AgentSession pre-authorizes the target against its own in-memory
      # `restart_targets` before ever calling `execute/4`, and passes an
      # empty context (see handle_agent_event({:restart_agent_request, ...})).
      # That call site must keep working exactly as before.
      assert {:ok, msg} =
               SystemCommand.execute(:restart, ["victim-agent"], %{},
                 router: router,
                 supervisor: sup
               )

      assert msg =~ "was not running"
    end
  end

  describe "execute(:unknown, ...)" do
    test "returns error with available commands" do
      assert {:error, msg} = SystemCommand.execute(:unknown, ["/foo"], %{})
      assert msg =~ "Unknown command '/foo'"
      assert msg =~ "/restart"
    end
  end

  # --- helpers ---

  defp safe_stop(pid) do
    if Process.alive?(pid) do
      GenServer.stop(pid, :normal, 1_000)
    end
  catch
    :exit, _ -> :ok
  end
end
