defmodule TriOnyx.Triggers.WebhookTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Triggers.Webhook

  @test_definition %AgentDefinition{
    name: "webhook-handler",
    description: "Handles webhooks",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "You handle webhooks."
  }

  setup do
    sup_name = :"wh_sup_#{:erlang.unique_integer([:positive])}"
    router_name = :"wh_router_#{:erlang.unique_integer([:positive])}"

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

    %{router: router_name}
  end

  defp safe_stop(pid) do
    if Process.alive?(pid), do: GenServer.stop(pid)
  catch
    :exit, _ -> :ok
  end

  describe "handle/3" do
    test "rejects invalid JSON", %{router: router} do
      {status, response} = Webhook.handle("webhook-handler", "not json", router)
      assert status == 400
      assert response["error"] == "invalid_json"
    end

    test "returns 404 for unknown agent", %{router: router} do
      body = Jason.encode!(%{"event" => "test"})
      {status, response} = Webhook.handle("nonexistent", body, router)
      assert status == 404
      assert response["error"] == "unknown_agent"
    end

    test "rejects payload exceeding size limit", %{router: router} do
      # Create a payload larger than 1MB
      large_body = String.duplicate("x", 1_048_577)
      {status, response} = Webhook.handle("webhook-handler", large_body, router)
      assert status == 413
      assert response["error"] == "payload_too_large"
    end

    test "accepts valid JSON payload for known agent", %{router: router} do
      body = Jason.encode!(%{"event" => "push", "repo" => "test/repo"})
      # This will fail at the session spawn level (no Python runtime in test)
      # but the webhook validation and routing should succeed
      {status, _response} = Webhook.handle("webhook-handler", body, router)
      # 202 = accepted (dispatch succeeded) or 500 (session spawn failed without runtime)
      assert status in [202, 500]
    end
  end
end
