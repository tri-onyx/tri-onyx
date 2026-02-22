defmodule TriOnyx.Triggers.SchedulerTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Triggers.Scheduler

  @test_definition %AgentDefinition{
    name: "heartbeat-agent",
    description: "Agent with heartbeat",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "You run on heartbeat."
  }

  setup do
    sup_name = :"sched_sup_#{:erlang.unique_integer([:positive])}"
    router_name = :"sched_router_#{:erlang.unique_integer([:positive])}"
    sched_name = :"sched_#{:erlang.unique_integer([:positive])}"

    {:ok, sup_pid} = AgentSupervisor.start_link(name: sup_name)

    {:ok, router_pid} =
      TriggerRouter.start_link(
        name: router_name,
        supervisor: sup_name,
        definitions: [@test_definition]
      )

    {:ok, sched_pid} =
      Scheduler.start_link(
        name: sched_name,
        router: router_name
      )

    on_exit(fn ->
      safe_stop(sched_pid)
      safe_stop(router_pid)
      safe_stop(sup_pid)
    end)

    %{scheduler: sched_name, router: router_name, supervisor: sup_name}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "schedule_heartbeat/3" do
    test "schedules a heartbeat", %{scheduler: scheduler} do
      assert :ok = Scheduler.schedule_heartbeat(scheduler, "heartbeat-agent", 60_000)

      heartbeats = Scheduler.list_heartbeats(scheduler)
      assert length(heartbeats) == 1
      assert hd(heartbeats).agent_name == "heartbeat-agent"
      assert hd(heartbeats).interval_ms == 60_000
    end

    test "replaces existing heartbeat for same agent", %{scheduler: scheduler} do
      assert :ok = Scheduler.schedule_heartbeat(scheduler, "heartbeat-agent", 60_000)
      assert :ok = Scheduler.schedule_heartbeat(scheduler, "heartbeat-agent", 30_000)

      heartbeats = Scheduler.list_heartbeats(scheduler)
      assert length(heartbeats) == 1
      assert hd(heartbeats).interval_ms == 30_000
    end

    test "supports multiple agents", %{scheduler: scheduler} do
      assert :ok = Scheduler.schedule_heartbeat(scheduler, "agent-a", 10_000)
      assert :ok = Scheduler.schedule_heartbeat(scheduler, "agent-b", 20_000)

      heartbeats = Scheduler.list_heartbeats(scheduler)
      assert length(heartbeats) == 2
    end
  end

  describe "cancel_heartbeat/2" do
    test "cancels an existing heartbeat", %{scheduler: scheduler} do
      :ok = Scheduler.schedule_heartbeat(scheduler, "heartbeat-agent", 60_000)
      assert :ok = Scheduler.cancel_heartbeat(scheduler, "heartbeat-agent")
      assert Scheduler.list_heartbeats(scheduler) == []
    end

    test "returns error for unknown heartbeat", %{scheduler: scheduler} do
      assert {:error, :not_found} = Scheduler.cancel_heartbeat(scheduler, "nonexistent")
    end
  end

  describe "list_heartbeats/1" do
    test "returns empty list when no heartbeats", %{scheduler: scheduler} do
      assert Scheduler.list_heartbeats(scheduler) == []
    end
  end

  describe "set_enabled/2 and enabled?/1" do
    test "defaults to enabled", %{scheduler: scheduler} do
      assert Scheduler.enabled?(scheduler) == true
    end

    test "can be disabled", %{scheduler: scheduler} do
      assert :ok = Scheduler.set_enabled(scheduler, false)
      assert Scheduler.enabled?(scheduler) == false
    end

    test "can be re-enabled", %{scheduler: scheduler} do
      :ok = Scheduler.set_enabled(scheduler, false)
      assert :ok = Scheduler.set_enabled(scheduler, true)
      assert Scheduler.enabled?(scheduler) == true
    end
  end
end
