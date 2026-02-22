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
    fs_read: [],
    fs_write: [],
    system_prompt: "You are a test agent."
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
          definitions: [@test_definition]
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
