defmodule TriOnyx.TriggerRouterTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.TriggerRouter

  @test_definition %AgentDefinition{
    name: "test-agent",
    description: "A test agent",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Grep"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "You are a test agent."
  }

  @webhook_definition %AgentDefinition{
    name: "webhook-agent",
    description: "A webhook handler",
    model: "claude-haiku-4-5",
    tools: ["Read"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "You handle webhooks."
  }

  setup do
    # Start a fresh supervisor and router for each test
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

    %{router: router_name, supervisor: sup_name}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "start_link/1" do
    test "starts with initial definitions", %{router: router} do
      agents = TriggerRouter.list_agents(router)
      assert length(agents) == 1
      assert hd(agents).name == "test-agent"
    end

    test "starts with empty definitions" do
      name = :"empty_router_#{:erlang.unique_integer([:positive])}"
      {:ok, pid} = TriggerRouter.start_link(name: name, definitions: [])
      assert TriggerRouter.list_agents(name) == []
      GenServer.stop(pid)
    end
  end

  describe "register_agent/2" do
    test "registers a new agent", %{router: router} do
      assert :ok = TriggerRouter.register_agent(router, @webhook_definition)
      agents = TriggerRouter.list_agents(router)
      assert length(agents) == 2
      names = Enum.map(agents, & &1.name) |> Enum.sort()
      assert names == ["test-agent", "webhook-agent"]
    end

    test "overwrites existing agent with same name", %{router: router} do
      updated = %{@test_definition | description: "Updated description"}
      assert :ok = TriggerRouter.register_agent(router, updated)
      {:ok, def} = TriggerRouter.get_agent(router, "test-agent")
      assert def.description == "Updated description"
    end
  end

  describe "unregister_agent/2" do
    test "removes a registered agent", %{router: router} do
      assert :ok = TriggerRouter.unregister_agent(router, "test-agent")
      assert TriggerRouter.list_agents(router) == []
    end

    test "returns error for unknown agent", %{router: router} do
      assert {:error, :not_found} = TriggerRouter.unregister_agent(router, "nonexistent")
    end
  end

  describe "get_agent/2" do
    test "returns definition for known agent", %{router: router} do
      assert {:ok, def} = TriggerRouter.get_agent(router, "test-agent")
      assert def.name == "test-agent"
    end

    test "returns error for unknown agent", %{router: router} do
      assert :error = TriggerRouter.get_agent(router, "nonexistent")
    end
  end

  describe "dispatch/2" do
    test "returns error for unknown agent", %{router: router} do
      event = %{
        type: :webhook,
        agent_name: "nonexistent",
        payload: "test",
        metadata: %{}
      }

      assert {:error, {:unknown_agent, "nonexistent"}} =
               TriggerRouter.dispatch(router, event)
    end

    # Note: Full dispatch tests that spawn agent sessions require the
    # Python runtime. These are covered in integration tests (Phase 10).
    # Here we test the routing logic and error handling.
  end

  describe "dispatch_reflection/2" do
    test "returns error for unknown agent", %{router: router} do
      assert {:error, {:unknown_agent, "nonexistent"}} =
               TriggerRouter.dispatch_reflection(router, "nonexistent")
    end

    # Full dispatch would spawn a Docker-backed session; that path is
    # exercised in integration tests. Here we only verify the routing
    # error for an unregistered agent.
  end
end
