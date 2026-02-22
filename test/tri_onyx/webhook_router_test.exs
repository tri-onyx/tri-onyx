defmodule TriOnyx.WebhookRouterTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.Router
  alias TriOnyx.TriggerRouter
  alias TriOnyx.WebhookRateLimiter
  alias TriOnyx.WebhookRegistry
  alias TriOnyx.WebhookSignature

  @test_definition %AgentDefinition{
    name: "router-test-agent",
    description: "Test agent for router tests",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "Test agent."
  }

  setup do
    # Ensure required processes are running
    {sup_pid, sup_owned} =
      ensure_started(AgentSupervisor, fn ->
        AgentSupervisor.start_link(name: AgentSupervisor)
      end)

    {router_pid, router_owned} =
      ensure_started(TriggerRouter, fn ->
        TriggerRouter.start_link(definitions: [@test_definition])
      end)

    unless router_owned do
      TriggerRouter.register_agent(@test_definition)
    end

    {registry_pid, registry_owned} =
      ensure_started(WebhookRegistry, fn ->
        webhooks_file = Path.join(["./tmp", "test-webhooks", "router_test.json"])
        File.mkdir_p!(Path.dirname(webhooks_file))
        WebhookRegistry.start_link(webhooks_file: webhooks_file)
      end)

    {limiter_pid, limiter_owned} =
      ensure_started(WebhookRateLimiter, fn ->
        WebhookRateLimiter.start_link()
      end)

    on_exit(fn ->
      if limiter_owned, do: safe_stop(limiter_pid)
      if registry_owned, do: safe_stop(registry_pid)
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

  # --- Management Endpoints ---

  describe "POST /webhook-endpoints" do
    test "creates a new endpoint and returns secret" do
      body = Jason.encode!(%{"label" => "test-create", "agents" => ["router-test-agent"]})

      conn =
        conn(:post, "/webhook-endpoints", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 201
      response = Jason.decode!(conn.resp_body)
      assert response["label"] == "test-create"
      assert is_binary(response["signing_secret"])
      assert String.starts_with?(response["id"], "whk_")
    end

    test "rejects invalid params" do
      body = Jason.encode!(%{"label" => "no-agents"})

      conn =
        conn(:post, "/webhook-endpoints", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 400
    end
  end

  describe "GET /webhook-endpoints" do
    test "lists endpoints without secrets" do
      # Create an endpoint first
      create_body = Jason.encode!(%{"label" => "list-test", "agents" => ["router-test-agent"]})

      conn(:post, "/webhook-endpoints", create_body)
      |> put_req_header("content-type", "application/json")
      |> call_router()

      conn = conn(:get, "/webhook-endpoints") |> call_router()

      assert conn.status == 200
      response = Jason.decode!(conn.resp_body)
      assert is_list(response["endpoints"])
      assert response["count"] >= 1

      # Should not contain secrets
      endpoint = List.first(response["endpoints"])
      refute Map.has_key?(endpoint, "signing_secret")
    end
  end

  describe "POST /hooks/:endpoint_id" do
    test "returns 404 for unknown endpoint" do
      body = Jason.encode!(%{"event" => "test"})

      conn =
        conn(:post, "/hooks/whk_nonexistent", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 404
    end

    test "returns 401 for missing signature" do
      # Create an endpoint
      create_body = Jason.encode!(%{"label" => "hook-test", "agents" => ["router-test-agent"]})

      create_conn =
        conn(:post, "/webhook-endpoints", create_body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      endpoint_id = Jason.decode!(create_conn.resp_body)["id"]

      # Try to hit it without a signature
      body = Jason.encode!(%{"event" => "test"})

      conn =
        conn(:post, "/hooks/#{endpoint_id}", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      assert conn.status == 401
    end

    test "accepts valid signed request" do
      # Create an endpoint
      create_body = Jason.encode!(%{
        "label" => "signed-test",
        "agents" => ["router-test-agent"]
      })

      create_conn =
        conn(:post, "/webhook-endpoints", create_body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      create_response = Jason.decode!(create_conn.resp_body)
      endpoint_id = create_response["id"]
      secret = create_response["signing_secret"]

      # Sign and send
      body = Jason.encode!(%{"event" => "test"})
      {signature, timestamp} = WebhookSignature.sign_default(secret, body)

      conn =
        conn(:post, "/hooks/#{endpoint_id}", body)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("x-webhook-signature", signature)
        |> put_req_header("x-webhook-timestamp", timestamp)
        |> call_router()

      # 202 = dispatched, 500 = session spawn failed (no Python runtime)
      assert conn.status in [202, 500]
    end
  end

  describe "DELETE /webhook-endpoints/:id" do
    test "deletes an existing endpoint" do
      create_body = Jason.encode!(%{"label" => "delete-test", "agents" => ["router-test-agent"]})

      create_conn =
        conn(:post, "/webhook-endpoints", create_body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      endpoint_id = Jason.decode!(create_conn.resp_body)["id"]

      conn =
        conn(:delete, "/webhook-endpoints/#{endpoint_id}")
        |> call_router()

      assert conn.status == 200
      assert Jason.decode!(conn.resp_body)["status"] == "deleted"
    end

    test "returns 404 for unknown endpoint" do
      conn =
        conn(:delete, "/webhook-endpoints/whk_nonexistent")
        |> call_router()

      assert conn.status == 404
    end
  end

  describe "POST /webhook-endpoints/:id/rotate-secret" do
    test "rotates secret and returns new one" do
      create_body = Jason.encode!(%{"label" => "rotate-test", "agents" => ["router-test-agent"]})

      create_conn =
        conn(:post, "/webhook-endpoints", create_body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      response = Jason.decode!(create_conn.resp_body)
      endpoint_id = response["id"]
      original_secret = response["signing_secret"]

      rotate_conn =
        conn(:post, "/webhook-endpoints/#{endpoint_id}/rotate-secret")
        |> call_router()

      assert rotate_conn.status == 200
      rotate_response = Jason.decode!(rotate_conn.resp_body)
      assert is_binary(rotate_response["new_secret"])
      assert rotate_response["new_secret"] != original_secret
      assert is_binary(rotate_response["previous_secret_valid_until"])
    end
  end

  describe "legacy POST /webhooks/:agent_name" do
    test "still works (deprecated)" do
      body = Jason.encode!(%{"event" => "test"})

      conn =
        conn(:post, "/webhooks/router-test-agent", body)
        |> put_req_header("content-type", "application/json")
        |> call_router()

      # Should still work — 202 or 500 (no runtime)
      assert conn.status in [202, 500]
    end
  end
end
