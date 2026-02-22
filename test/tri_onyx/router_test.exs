defmodule TriOnyx.RouterTest do
  use ExUnit.Case, async: false

  import Plug.Test
  import Plug.Conn

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.Router
  alias TriOnyx.TriggerRouter

  @test_definition %AgentDefinition{
    name: "test-agent",
    description: "A test agent",
    model: "claude-sonnet-4-20250514",
    tools: ["Read", "Grep"],
    network: :none,
    fs_read: ["/workspace/repo/src/**"],
    fs_write: [],
    system_prompt: "You are a test agent."
  }

  setup do
    # The application supervision tree may already have these running.
    # Use existing processes if available, otherwise start fresh.
    {sup_pid, sup_owned} = ensure_started(AgentSupervisor, fn ->
      AgentSupervisor.start_link(name: AgentSupervisor)
    end)

    {router_pid, router_owned} = ensure_started(TriggerRouter, fn ->
      TriggerRouter.start_link(definitions: [@test_definition])
    end)

    # Register the test definition if using an already-running router
    unless router_owned do
      TriggerRouter.register_agent(@test_definition)
    end

    on_exit(fn ->
      if router_owned, do: safe_stop(router_pid)
      if sup_owned, do: safe_stop(sup_pid)
    end)

    :ok
  end

  defp ensure_started(name, start_fn) do
    case Process.whereis(name) do
      nil ->
        {:ok, pid} = start_fn.()
        {pid, true}

      pid ->
        {pid, false}
    end
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  defp call_router(conn) do
    Router.call(conn, Router.init([]))
  end

  describe "GET /health" do
    test "returns 200 with status" do
      conn = conn(:get, "/health") |> call_router()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
      assert is_integer(body["active_sessions"])
    end
  end

  describe "GET /agents" do
    test "lists registered agents" do
      conn = conn(:get, "/agents") |> call_router()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["agents"])
      assert length(body["agents"]) >= 1

      agent = Enum.find(body["agents"], &(&1["name"] == "test-agent"))
      assert agent, "expected test-agent in agents list"
      assert agent["status"] == "inactive"
    end
  end

  describe "GET /agents/:name" do
    test "returns agent detail for known agent" do
      conn = conn(:get, "/agents/test-agent") |> call_router()

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["name"] == "test-agent"
      assert body["tools"] == ["Read", "Grep"]
      assert body["fs_read"] == ["/workspace/repo/src/**"]
      assert body["status"] == "inactive"
    end

    test "returns 404 for unknown agent" do
      conn = conn(:get, "/agents/nonexistent") |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "agent_not_found"
    end
  end

  describe "POST /webhooks/:agent_name" do
    test "rejects invalid JSON" do
      conn =
        conn(:post, "/webhooks/test-agent", "not json")
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_json"
    end

    test "returns 404 for unknown agent" do
      conn =
        conn(:post, "/webhooks/nonexistent", Jason.encode!(%{"event" => "test"}))
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unknown_agent"
    end
  end

  describe "POST /messages" do
    test "rejects missing authorization" do
      payload = Jason.encode!(%{"agent" => "test-agent", "content" => "hello"})

      conn =
        conn(:post, "/messages", payload)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 401
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "unauthorized"
    end

    test "rejects invalid JSON" do
      conn =
        conn(:post, "/messages", "not json")
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", "Bearer test-key")
        |> call_router()

      assert conn.status == 400
    end
  end

  describe "POST /agents/:name/stop" do
    test "returns 404 when no active session" do
      conn =
        conn(:post, "/agents/test-agent/stop", "")
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "no_active_session"
    end
  end

  describe "catch-all" do
    test "returns 404 for unknown routes" do
      conn = conn(:get, "/unknown") |> call_router()

      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "not_found"
    end
  end
end
