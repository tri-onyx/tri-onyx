defmodule TriOnyx.WebhookRegistryTest do
  use ExUnit.Case

  alias TriOnyx.WebhookEndpoint
  alias TriOnyx.WebhookRegistry

  setup do
    # Use unique names for each test to avoid ETS table conflicts
    suffix = :erlang.unique_integer([:positive])
    table_name = :"webhook_test_#{suffix}"
    registry_name = :"registry_test_#{suffix}"
    webhooks_file = Path.join(["./tmp", "test-webhooks", "webhooks_#{suffix}.json"])

    File.mkdir_p!(Path.dirname(webhooks_file))

    {:ok, pid} =
      WebhookRegistry.start_link(
        name: registry_name,
        ets_table: table_name,
        webhooks_file: webhooks_file
      )

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm(webhooks_file)
      File.rm(webhooks_file <> ".tmp")
    end)

    %{registry: registry_name, table: table_name, webhooks_file: webhooks_file}
  end

  describe "create/2" do
    test "creates and stores a new endpoint", %{registry: registry, table: table} do
      params = %{"label" => "test-hook", "agents" => ["agent-a"]}

      assert {:ok, endpoint} = WebhookRegistry.create(registry, params)
      assert endpoint.label == "test-hook"
      assert endpoint.agents == ["agent-a"]
      assert String.starts_with?(endpoint.id, "whk_")

      # Should be in ETS
      assert {:ok, ^endpoint} = WebhookRegistry.lookup(endpoint.id, table)
    end

    test "rejects invalid params", %{registry: registry} do
      assert {:error, _} = WebhookRegistry.create(registry, %{"label" => "no-agents"})
    end

    test "persists to disk", %{registry: registry, webhooks_file: file} do
      params = %{"label" => "persistent", "agents" => ["agent-a"]}
      {:ok, _endpoint} = WebhookRegistry.create(registry, params)

      # File should exist and contain JSON
      assert File.exists?(file)
      {:ok, content} = File.read(file)
      {:ok, data} = Jason.decode(content)
      assert length(data) == 1
      assert hd(data)["label"] == "persistent"
    end
  end

  describe "list/1" do
    test "returns all endpoints sorted by creation time", %{registry: registry} do
      {:ok, _} = WebhookRegistry.create(registry, %{"label" => "first", "agents" => ["a"]})
      {:ok, _} = WebhookRegistry.create(registry, %{"label" => "second", "agents" => ["b"]})

      endpoints = WebhookRegistry.list(registry)
      assert length(endpoints) == 2
      labels = Enum.map(endpoints, & &1.label)
      assert labels == ["first", "second"]
    end

    test "returns empty list when no endpoints", %{registry: registry} do
      assert [] == WebhookRegistry.list(registry)
    end
  end

  describe "lookup/2" do
    test "returns endpoint by ID", %{registry: registry, table: table} do
      {:ok, endpoint} = WebhookRegistry.create(registry, %{"label" => "find-me", "agents" => ["a"]})
      assert {:ok, found} = WebhookRegistry.lookup(endpoint.id, table)
      assert found.label == "find-me"
    end

    test "returns :error for unknown ID", %{table: table} do
      assert :error = WebhookRegistry.lookup("whk_nonexistent", table)
    end
  end

  describe "update/3" do
    test "updates allowed fields", %{registry: registry, table: table} do
      {:ok, endpoint} = WebhookRegistry.create(registry, %{"label" => "original", "agents" => ["a"]})

      assert {:ok, updated} =
               WebhookRegistry.update(registry, endpoint.id, %{
                 "label" => "updated",
                 "agents" => ["a", "b"],
                 "enabled" => false,
                 "rate_limit" => 30
               })

      assert updated.label == "updated"
      assert updated.agents == ["a", "b"]
      assert updated.enabled == false
      assert updated.rate_limit == 30

      # ETS should reflect update
      {:ok, from_ets} = WebhookRegistry.lookup(endpoint.id, table)
      assert from_ets.label == "updated"
    end

    test "does not change signing_secret on update", %{registry: registry} do
      {:ok, endpoint} = WebhookRegistry.create(registry, %{"label" => "test", "agents" => ["a"]})
      original_secret = endpoint.signing_secret

      {:ok, updated} = WebhookRegistry.update(registry, endpoint.id, %{"label" => "new-label"})
      assert updated.signing_secret == original_secret
    end

    test "returns error for unknown endpoint", %{registry: registry} do
      assert {:error, :not_found} =
               WebhookRegistry.update(registry, "whk_nonexistent", %{"label" => "x"})
    end
  end

  describe "delete/2" do
    test "removes endpoint", %{registry: registry, table: table} do
      {:ok, endpoint} = WebhookRegistry.create(registry, %{"label" => "deleteme", "agents" => ["a"]})
      assert :ok = WebhookRegistry.delete(registry, endpoint.id)
      assert :error = WebhookRegistry.lookup(endpoint.id, table)
    end

    test "returns error for unknown endpoint", %{registry: registry} do
      assert {:error, :not_found} = WebhookRegistry.delete(registry, "whk_nonexistent")
    end
  end

  describe "rotate_secret/2" do
    test "generates new secret and preserves old", %{registry: registry, table: table} do
      {:ok, endpoint} = WebhookRegistry.create(registry, %{"label" => "rotate", "agents" => ["a"]})
      original_secret = endpoint.signing_secret

      assert {:ok, rotated} = WebhookRegistry.rotate_secret(registry, endpoint.id)
      assert rotated.signing_secret != original_secret
      assert rotated.previous_secret == original_secret
      assert rotated.rotated_at != nil

      # ETS should have the rotated version
      {:ok, from_ets} = WebhookRegistry.lookup(endpoint.id, table)
      assert from_ets.signing_secret == rotated.signing_secret
      assert from_ets.previous_secret == original_secret
    end

    test "returns error for unknown endpoint", %{registry: registry} do
      assert {:error, :not_found} = WebhookRegistry.rotate_secret(registry, "whk_nonexistent")
    end
  end

  describe "persistence roundtrip" do
    test "loads endpoints from disk on startup", %{webhooks_file: file} do
      # Write a valid webhooks file
      endpoint_data = [
        %{
          "id" => "whk_test123abc",
          "label" => "from-disk",
          "agents" => ["agent-x"],
          "signing_secret" => "a" |> String.duplicate(64),
          "signing_mode" => "default",
          "enabled" => true,
          "rate_limit" => 60,
          "allowed_ips" => nil,
          "created_at" => "2026-01-01T00:00:00Z",
          "rotated_at" => nil,
          "previous_secret" => nil
        }
      ]

      File.write!(file, Jason.encode!(endpoint_data))

      # Start a new registry that reads from this file
      suffix = :erlang.unique_integer([:positive])
      table_name = :"webhook_load_#{suffix}"
      registry_name = :"registry_load_#{suffix}"

      {:ok, pid} =
        WebhookRegistry.start_link(
          name: registry_name,
          ets_table: table_name,
          webhooks_file: file
        )

      assert {:ok, endpoint} = WebhookRegistry.lookup("whk_test123abc", table_name)
      assert endpoint.label == "from-disk"
      assert endpoint.agents == ["agent-x"]

      GenServer.stop(pid)
    end
  end
end
