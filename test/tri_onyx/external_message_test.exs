defmodule TriOnyx.Triggers.ExternalMessageTest do
  use ExUnit.Case

  alias TriOnyx.AgentDefinition
  alias TriOnyx.AgentSupervisor
  alias TriOnyx.TriggerRouter
  alias TriOnyx.Triggers.ExternalMessage

  @test_definition %AgentDefinition{
    name: "message-handler",
    description: "Handles messages",
    model: "claude-sonnet-4-20250514",
    tools: ["Read"],
    network: :none,
    fs_read: [],
    fs_write: [],
    system_prompt: "You handle messages."
  }

  setup do
    sup_name = :"em_sup_#{:erlang.unique_integer([:positive])}"
    router_name = :"em_router_#{:erlang.unique_integer([:positive])}"

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
      {status, response} = ExternalMessage.handle("not json", "some-key", router)
      assert status == 400
      assert response["error"] == "invalid_json"
    end

    test "rejects missing API key", %{router: router} do
      body = Jason.encode!(%{"agent" => "message-handler", "content" => "hello"})
      {status, response} = ExternalMessage.handle(body, nil, router)
      assert status == 401
      assert response["error"] == "unauthorized"
    end

    test "rejects empty API key", %{router: router} do
      body = Jason.encode!(%{"agent" => "message-handler", "content" => "hello"})
      {status, response} = ExternalMessage.handle(body, "", router)
      assert status == 401
      assert response["error"] == "unauthorized"
    end

    test "rejects missing required fields", %{router: router} do
      body = Jason.encode!(%{"content" => "hello"})
      {status, response} = ExternalMessage.handle(body, "test-key", router)
      assert status == 400
      assert response["error"] == "missing_field"
      assert response["field"] == "agent"
    end

    test "rejects missing content field", %{router: router} do
      body = Jason.encode!(%{"agent" => "message-handler"})
      {status, response} = ExternalMessage.handle(body, "test-key", router)
      assert status == 400
      assert response["error"] == "missing_field"
      assert response["field"] == "content"
    end

    test "returns 404 for unknown agent", %{router: router} do
      body = Jason.encode!(%{"agent" => "nonexistent", "content" => "hello"})
      {status, response} = ExternalMessage.handle(body, "test-key", router)
      assert status == 404
      assert response["error"] == "unknown_agent"
    end
  end
end
