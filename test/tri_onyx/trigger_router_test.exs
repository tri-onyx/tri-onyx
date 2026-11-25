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
    system_prompt: "You are a test agent."
  }

  @webhook_definition %AgentDefinition{
    name: "webhook-agent",
    description: "A webhook handler",
    model: "claude-haiku-4-5",
    tools: ["Read"],
    network: :none,
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

  describe "dispatch/2 into an already-running session" do
    # A session started by a clean trigger (cron, heartbeat, the owner's
    # verified chat) is found by find_session/3 for any later trigger that
    # carries no session_key — webhooks, email, calendar. Those inputs are
    # attacker-controlled and must taint the session exactly as they would
    # had they started it ("Webhook payloads always taint the receiving
    # agent session" — WebhookReceiver moduledoc).
    #
    # The stub below stands in for the Docker-backed session process: it
    # sits in the real AgentSupervisor and runs the real
    # AgentSession.handle_call/3 for status and prompt calls, so the taint
    # observed is what a live session would record.
    defmodule ClassifiedStubSession do
      use GenServer

      def start_link(state), do: GenServer.start_link(__MODULE__, state)

      @impl GenServer
      def init(state), do: {:ok, state}

      @impl GenServer
      def handle_call(msg, from, state), do: TriOnyx.AgentSession.handle_call(msg, from, state)

      @impl GenServer
      def handle_info(_msg, state), do: {:noreply, state}
    end

    defp start_clean_session(supervisor, definition) do
      state = %{
        id: "stub-#{:erlang.unique_integer([:positive])}",
        definition: definition,
        port: nil,
        capability_level: :low,
        taint_level: :low,
        sensitivity_level: :low,
        information_level: :low,
        information_sources: [],
        input_risk: :low,
        effective_risk: :low,
        started_at: DateTime.utc_now(),
        status: :starting,
        trigger_type: :cron,
        prompt_queue: [],
        session_key: nil,
        session_label: nil,
        mode: :normal
      }

      {:ok, pid} = DynamicSupervisor.start_child(supervisor, {ClassifiedStubSession, state})
      pid
    end

    for {trigger, expected_taint, expected_sensitivity} <- [
          {:webhook, :high, :low},
          {:unverified_input, :high, :medium}
        ] do
      test "#{trigger} payload routed into a clean running session taints it",
           %{router: router, supervisor: supervisor} do
        pid = start_clean_session(supervisor, @test_definition)

        event = %{
          type: unquote(trigger),
          agent_name: "test-agent",
          payload: ~s({"attacker":"controlled"}),
          metadata: %{endpoint_id: "whk_test", source_ip: "203.0.113.7"}
        }

        assert {:ok, ^pid} = TriggerRouter.dispatch(router, event)

        status = TriOnyx.AgentSession.get_status(pid)

        assert status.taint_level == unquote(expected_taint),
               "#{unquote(trigger)} content reached a running session without tainting it: " <>
                 "taint_level is #{inspect(status.taint_level)}, expected " <>
                 "#{inspect(unquote(expected_taint))} (what a fresh session for this trigger gets)"

        assert status.sensitivity_level == unquote(expected_sensitivity)
      end
    end

    test "inter-agent metadata labels are kept as the sender's levels",
         %{router: router, supervisor: supervisor} do
      pid = start_clean_session(supervisor, @test_definition)

      event = %{
        type: :inter_agent,
        agent_name: "test-agent",
        payload: "{}",
        metadata: %{from_agent: "peer", taint_level: :low, sensitivity_level: :low}
      }

      assert {:ok, ^pid} = TriggerRouter.dispatch(router, event)
      assert TriOnyx.AgentSession.get_status(pid).taint_level == :low
    end

    test "clean triggers leave a clean running session clean",
         %{router: router, supervisor: supervisor} do
      pid = start_clean_session(supervisor, @test_definition)

      event = %{type: :heartbeat, agent_name: "test-agent", payload: "tick", metadata: %{}}

      assert {:ok, ^pid} = TriggerRouter.dispatch(router, event)
      status = TriOnyx.AgentSession.get_status(pid)
      assert status.taint_level == :low
      assert status.sensitivity_level == :low
    end
  end

  describe "load_agents/1" do
    # Boot path regression: TriOnyx.Application delegates initial agent
    # loading to TriggerRouter.load_agents/1. On the first load every agent
    # counts as "added", so heartbeats, crons, AND reflections must all be
    # scheduled (reflections were previously skipped at boot).
    test "first load schedules reflections for agents that declare one", %{router: router} do
      alias TriOnyx.Triggers.Scheduler

      agents_dir = "./tmp/test-agents-#{:erlang.unique_integer([:positive])}"
      File.mkdir_p!(agents_dir)

      File.write!(Path.join(agents_dir, "reflective-agent.md"), """
      ---
      name: reflective-agent
      tools: Read
      reflection: "0 23 * * *"
      ---

      A reflective test agent.
      """)

      previous_dir = Application.get_env(:tri_onyx, :agents_dir)
      Application.put_env(:tri_onyx, :agents_dir, agents_dir)

      on_exit(fn ->
        if previous_dir do
          Application.put_env(:tri_onyx, :agents_dir, previous_dir)
        else
          Application.delete_env(:tri_onyx, :agents_dir)
        end

        # load_agents schedules on the globally named Scheduler — clean up
        Scheduler.cancel_reflection("reflective-agent")
        File.rm_rf!(agents_dir)
      end)

      assert {:ok, 1} = TriggerRouter.load_agents(router)

      assert {:ok, definition} = TriggerRouter.get_agent(router, "reflective-agent")
      assert definition.reflection == "0 23 * * *"

      reflections = Scheduler.list_reflections()
      assert Enum.any?(reflections, fn {name, _job} -> name == "reflective-agent" end)
    end
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
