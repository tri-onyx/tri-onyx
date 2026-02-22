defmodule TriOnyx.WebhookReceiverTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.TriggerRouter
  alias TriOnyx.WebhookEndpoint
  alias TriOnyx.WebhookRateLimiter
  alias TriOnyx.WebhookReceiver
  alias TriOnyx.WebhookRegistry
  alias TriOnyx.WebhookSignature

  @test_definition %AgentDefinition{
    name: "receiver-test-agent",
    description: "Test agent for webhook receiver",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "Test agent."
  }

  setup do
    suffix = :erlang.unique_integer([:positive])

    # Start all required processes
    sup_name = :"recv_sup_#{suffix}"
    router_name = :"recv_router_#{suffix}"
    registry_name = :"recv_registry_#{suffix}"
    limiter_name = :"recv_limiter_#{suffix}"
    reg_table = :"recv_reg_table_#{suffix}"
    rate_table = :"recv_rate_table_#{suffix}"
    webhooks_file = Path.join(["./tmp", "test-webhooks", "recv_#{suffix}.json"])

    File.mkdir_p!(Path.dirname(webhooks_file))

    {:ok, sup_pid} = AgentSupervisor.start_link(name: sup_name)

    {:ok, router_pid} =
      TriggerRouter.start_link(
        name: router_name,
        supervisor: sup_name,
        definitions: [@test_definition]
      )

    {:ok, registry_pid} =
      WebhookRegistry.start_link(
        name: registry_name,
        ets_table: reg_table,
        webhooks_file: webhooks_file
      )

    {:ok, limiter_pid} =
      WebhookRateLimiter.start_link(
        name: limiter_name,
        ets_table: rate_table
      )

    on_exit(fn ->
      for pid <- [limiter_pid, registry_pid, router_pid, sup_pid] do
        try do
          if Process.alive?(pid), do: GenServer.stop(pid)
        catch
          :exit, _ -> :ok
        end
      end

      File.rm(webhooks_file)
    end)

    %{
      router: router_name,
      registry: registry_name,
      reg_table: reg_table,
      rate_table: rate_table
    }
  end

  defp create_endpoint(registry, opts \\ []) do
    params = %{
      "label" => Keyword.get(opts, :label, "test-hook"),
      "agents" => Keyword.get(opts, :agents, ["receiver-test-agent"]),
      "signing_mode" => Keyword.get(opts, :signing_mode, "default"),
      "rate_limit" => Keyword.get(opts, :rate_limit, 60)
    }

    params =
      case Keyword.get(opts, :allowed_ips) do
        nil -> params
        ips -> Map.put(params, "allowed_ips", ips)
      end

    {:ok, endpoint} = WebhookRegistry.create(registry, params)
    endpoint
  end

  defp make_signed_request(endpoint, body) do
    {signature, timestamp} = WebhookSignature.sign_default(endpoint.signing_secret, body)

    headers = [
      {"content-type", "application/json"},
      {"x-webhook-signature", signature},
      {"x-webhook-timestamp", timestamp}
    ]

    headers
  end

  describe "handle/5 — happy path" do
    test "accepts valid signed request", ctx do
      endpoint = create_endpoint(ctx.registry)
      body = Jason.encode!(%{"event" => "test"})
      headers = make_signed_request(endpoint, body)

      {status, response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      # 202 = dispatched, 500 = session spawn failed (no Python runtime in tests)
      assert status in [202, 500]

      if status == 202 do
        assert response["status"] in ["accepted", "partial"]
        assert response["endpoint"] == endpoint.id
      end
    end
  end

  describe "handle/5 — unknown endpoint" do
    test "returns 404 for unknown endpoint ID", ctx do
      body = Jason.encode!(%{"event" => "test"})

      {status, response} =
        WebhookReceiver.handle("whk_nonexistent", body, [], "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status == 404
      assert response["error"] == "not_found"
    end
  end

  describe "handle/5 — disabled endpoint" do
    test "returns 404 for disabled endpoint", ctx do
      endpoint = create_endpoint(ctx.registry)
      WebhookRegistry.update(ctx.registry, endpoint.id, %{"enabled" => false})

      body = Jason.encode!(%{"event" => "test"})
      headers = make_signed_request(endpoint, body)

      {status, response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status == 404
      assert response["error"] == "not_found"
    end
  end

  describe "handle/5 — signature verification" do
    test "rejects missing signature", ctx do
      endpoint = create_endpoint(ctx.registry)
      body = Jason.encode!(%{"event" => "test"})
      headers = [{"content-type", "application/json"}]

      {status, response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status == 401
      assert response["error"] == "unauthorized"
    end

    test "rejects invalid signature", ctx do
      endpoint = create_endpoint(ctx.registry)
      body = Jason.encode!(%{"event" => "test"})
      timestamp = Integer.to_string(System.system_time(:second))

      headers = [
        {"x-webhook-signature", "sha256=0000000000000000000000000000000000000000000000000000000000000000"},
        {"x-webhook-timestamp", timestamp}
      ]

      {status, response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status == 401
      assert response["error"] == "unauthorized"
    end

    test "skips verification for :none mode", ctx do
      endpoint = create_endpoint(ctx.registry, signing_mode: "none")
      body = Jason.encode!(%{"event" => "test"})
      headers = [{"content-type", "application/json"}]

      {status, _response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      # Should pass signature check (202 or 500 from session spawn)
      assert status in [202, 500]
    end
  end

  describe "handle/5 — IP allowlist" do
    test "rejects request from non-allowed IP", ctx do
      endpoint = create_endpoint(ctx.registry, allowed_ips: ["192.168.1.0/24"])
      body = Jason.encode!(%{"event" => "test"})
      headers = make_signed_request(endpoint, body)

      {status, response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status == 403
      assert response["error"] == "forbidden"
    end

    test "accepts request from allowed IP", ctx do
      endpoint = create_endpoint(ctx.registry, allowed_ips: ["10.0.0.0/8"])
      body = Jason.encode!(%{"event" => "test"})
      headers = make_signed_request(endpoint, body)

      {status, _response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      # Should pass IP check (202 or 500 from session spawn)
      assert status in [202, 500]
    end

    test "accepts request from exact IP match", ctx do
      endpoint = create_endpoint(ctx.registry, allowed_ips: ["10.0.0.1"])
      body = Jason.encode!(%{"event" => "test"})
      headers = make_signed_request(endpoint, body)

      {status, _response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status in [202, 500]
    end
  end

  describe "handle/5 — rate limiting" do
    test "rejects when rate limit exceeded", ctx do
      endpoint = create_endpoint(ctx.registry, rate_limit: 2)
      body = Jason.encode!(%{"event" => "test"})
      headers = make_signed_request(endpoint, body)

      opts = [
        registry_table: ctx.reg_table,
        rate_limiter_table: ctx.rate_table,
        router: ctx.router
      ]

      # Use up the rate limit
      WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1", opts)
      WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1", opts)

      # Third request should be rate limited
      {status, response} = WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1", opts)

      assert status == 429
      assert response["error"] == "rate_limited"
      assert is_integer(response["retry_after"])
    end
  end

  describe "handle/5 — payload validation" do
    test "rejects non-JSON body", ctx do
      endpoint = create_endpoint(ctx.registry, signing_mode: "none")
      body = "not json at all"
      headers = [{"content-type", "application/json"}]

      {status, response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status == 400
      assert response["error"] == "invalid_json"
    end

    test "rejects oversized payload", ctx do
      endpoint = create_endpoint(ctx.registry, signing_mode: "none")
      body = String.duplicate("x", 1_048_577)
      headers = [{"content-type", "application/json"}]

      {status, response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      assert status == 413
      assert response["error"] == "payload_too_large"
    end
  end

  describe "handle/5 — secret rotation" do
    test "accepts old secret during rotation window", ctx do
      endpoint = create_endpoint(ctx.registry)
      old_secret = endpoint.signing_secret

      # Rotate the secret
      {:ok, _rotated} = WebhookRegistry.rotate_secret(ctx.registry, endpoint.id)

      # Sign with the old secret
      body = Jason.encode!(%{"event" => "test"})
      {signature, timestamp} = WebhookSignature.sign_default(old_secret, body)

      headers = [
        {"x-webhook-signature", signature},
        {"x-webhook-timestamp", timestamp}
      ]

      {status, _response} =
        WebhookReceiver.handle(endpoint.id, body, headers, "10.0.0.1",
          registry_table: ctx.reg_table,
          rate_limiter_table: ctx.rate_table,
          router: ctx.router
        )

      # Should accept old secret during rotation window
      assert status in [202, 500]
    end
  end
end
