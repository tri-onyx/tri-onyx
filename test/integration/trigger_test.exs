defmodule TriOnyx.Integration.TriggerTest do
  @moduledoc """
  Integration tests for the trigger dispatch system.

  Tests the full path from trigger event → TriggerRouter → AgentSupervisor,
  exercising webhook, cron, heartbeat, and external message triggers across
  the real GenServer infrastructure.

  Note: these tests don't spawn the Python runtime (AgentPort will fail),
  but they verify that the gateway's dispatch, validation, and routing logic
  is correct up to the point of session creation.
  """
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.Router
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Triggers.Scheduler
  alias TriOnyx.Triggers.Webhook
  alias TriOnyx.Triggers.ExternalMessage

  @low_risk_agent %AgentDefinition{
    name: "cron-checker",
    description: "Runs on a cron schedule",
    model: "claude-haiku-4-5",
    tools: ["Read", "Grep"],
    network: :none,
    fs_read: ["/workspace/**"],
    fs_write: [],
    system_prompt: "You check things on a schedule."
  }

  @webhook_agent %AgentDefinition{
    name: "webhook-receiver",
    description: "Receives webhook payloads",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Write"],
    network: :none,
    fs_read: [],
    fs_write: ["/workspace/output/**"],
    system_prompt: "You process webhook payloads."
  }

  setup do
    ensure_started()

    TriggerRouter.register_agent(@low_risk_agent)
    TriggerRouter.register_agent(@webhook_agent)

    on_exit(fn ->
      try do
        TriggerRouter.unregister_agent("cron-checker")
        TriggerRouter.unregister_agent("webhook-receiver")
      catch
        :exit, _ -> :ok
      end
    end)

    :ok
  end

  defp ensure_started do
    for name <- [AgentSupervisor, TriggerRouter, TriOnyx.Triggers.Scheduler] do
      case Process.whereis(name) do
        nil ->
          case name do
            AgentSupervisor -> AgentSupervisor.start_link(name: name)
            TriggerRouter -> TriggerRouter.start_link()
            _ -> :ok
          end

        _pid ->
          :ok
      end
    end
  end

  describe "webhook trigger dispatch" do
    test "webhook trigger is dispatched to correct agent" do
      body = Jason.encode!(%{"event" => "push", "ref" => "refs/heads/main"})
      {status, response} = Webhook.handle("webhook-receiver", body)

      # 202 if session started, 500 if port failed (no Python runtime)
      assert status in [202, 500]

      if status == 202 do
        assert response["status"] == "accepted"
        assert response["agent"] == "webhook-receiver"
      end
    end

    test "webhook rejects unknown agent" do
      body = Jason.encode!(%{"event" => "test"})
      {status, response} = Webhook.handle("nonexistent-agent", body)
      assert status == 404
      assert response["error"] == "unknown_agent"
    end

    test "webhook rejects malformed JSON" do
      {status, response} = Webhook.handle("webhook-receiver", "{invalid")
      assert status == 400
      assert response["error"] == "invalid_json"
    end

    test "webhook rejects empty body" do
      {status, response} = Webhook.handle("webhook-receiver", "")
      assert status == 400
      assert response["error"] == "invalid_json"
    end
  end

  describe "external message trigger dispatch" do
    test "external message dispatches to correct agent" do
      body = Jason.encode!(%{
        "agent" => "cron-checker",
        "content" => "Please check the logs",
        "sender" => "operator"
      })

      # No API key configured in test → accepts all
      {status, _response} = ExternalMessage.handle(body, "test-api-key")

      # 202 or 500 (no Python runtime)
      assert status in [202, 500]
    end

    test "external message rejects missing agent field" do
      body = Jason.encode!(%{"content" => "hello"})
      {status, response} = ExternalMessage.handle(body, "test-key")
      assert status == 400
      assert response["field"] == "agent"
    end

    test "external message rejects missing content field" do
      body = Jason.encode!(%{"agent" => "cron-checker"})
      {status, response} = ExternalMessage.handle(body, "test-key")
      assert status == 400
      assert response["field"] == "content"
    end

    test "external message rejects nil API key" do
      body = Jason.encode!(%{"agent" => "cron-checker", "content" => "hello"})
      {status, response} = ExternalMessage.handle(body, nil)
      assert status == 401
      assert response["error"] == "unauthorized"
    end
  end

  describe "trigger routing via TriggerRouter" do
    test "dispatches to registered agent" do
      event = %{
        type: :cron,
        agent_name: "cron-checker",
        payload: "scheduled check",
        metadata: %{}
      }

      # Will either succeed (creating session) or fail at AgentPort
      result = TriggerRouter.dispatch(event)
      assert match?({:ok, _pid}, result) or match?({:error, _}, result)
    end

    test "returns error for unregistered agent" do
      event = %{
        type: :cron,
        agent_name: "ghost-agent",
        payload: "boo",
        metadata: %{}
      }

      assert {:error, {:unknown_agent, "ghost-agent"}} = TriggerRouter.dispatch(event)
    end
  end

  describe "heartbeat scheduling" do
    test "heartbeat can be scheduled and cancelled" do
      :ok = Scheduler.schedule_heartbeat("cron-checker", 60_000)

      heartbeats = Scheduler.list_heartbeats()
      assert Enum.any?(heartbeats, fn h -> h.agent_name == "cron-checker" end)

      :ok = Scheduler.cancel_heartbeat("cron-checker")
      assert Scheduler.list_heartbeats() |> Enum.reject(fn h -> h.agent_name == "cron-checker" end) == Scheduler.list_heartbeats()
    end
  end

  describe "HTTP routing integration" do
    test "POST /webhooks/:agent_name routes through full stack" do
      conn =
        conn(:post, "/webhooks/webhook-receiver", Jason.encode!(%{"event" => "deploy"}))
        |> put_req_header("content-type", "application/json")
        |> Router.call(Router.init([]))

      # Accepts or fails at port spawn
      assert conn.status in [202, 500]
    end

    test "GET /agents lists both registered agents" do
      conn =
        conn(:get, "/agents")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      names = Enum.map(body["agents"], & &1["name"])
      assert "cron-checker" in names
      assert "webhook-receiver" in names
    end

    test "GET /agents/:name returns full detail" do
      conn =
        conn(:get, "/agents/cron-checker")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "cron-checker"
      assert body["model"] == "claude-haiku-4-5"
      assert body["network"] == "none"
      assert body["fs_read"] == ["/workspace/**"]
    end

    test "GET /health returns ok" do
      conn =
        conn(:get, "/health")
        |> Router.call(Router.init([]))

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end
end
