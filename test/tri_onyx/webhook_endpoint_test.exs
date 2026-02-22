defmodule TriOnyx.WebhookEndpointTest do
  use ExUnit.Case

  alias TriOnyx.WebhookEndpoint

  describe "new/1" do
    test "creates endpoint with required fields" do
      params = %{
        "label" => "github-push",
        "agents" => ["code-reviewer"]
      }

      assert {:ok, endpoint} = WebhookEndpoint.new(params)
      assert String.starts_with?(endpoint.id, "whk_")
      assert endpoint.label == "github-push"
      assert endpoint.agents == ["code-reviewer"]
      assert endpoint.signing_mode == :default
      assert endpoint.enabled == true
      assert endpoint.rate_limit == 60
      assert endpoint.allowed_ips == nil
      assert is_binary(endpoint.signing_secret)
      assert byte_size(endpoint.signing_secret) == 64
    end

    test "accepts optional signing_mode" do
      params = %{
        "label" => "gh-webhook",
        "agents" => ["handler"],
        "signing_mode" => "github"
      }

      assert {:ok, endpoint} = WebhookEndpoint.new(params)
      assert endpoint.signing_mode == :github
    end

    test "accepts optional rate_limit" do
      params = %{
        "label" => "test",
        "agents" => ["handler"],
        "rate_limit" => 120
      }

      assert {:ok, endpoint} = WebhookEndpoint.new(params)
      assert endpoint.rate_limit == 120
    end

    test "accepts optional allowed_ips" do
      params = %{
        "label" => "test",
        "agents" => ["handler"],
        "allowed_ips" => ["10.0.0.1", "192.168.0.0/16"]
      }

      assert {:ok, endpoint} = WebhookEndpoint.new(params)
      assert endpoint.allowed_ips == ["10.0.0.1", "192.168.0.0/16"]
    end

    test "rejects missing label" do
      params = %{"agents" => ["handler"]}
      assert {:error, {:missing_field, "label"}} = WebhookEndpoint.new(params)
    end

    test "rejects missing agents" do
      params = %{"label" => "test"}
      assert {:error, {:missing_field, "agents"}} = WebhookEndpoint.new(params)
    end

    test "rejects empty agents list" do
      params = %{"label" => "test", "agents" => []}
      assert {:error, _} = WebhookEndpoint.new(params)
    end

    test "rejects invalid signing mode" do
      params = %{"label" => "test", "agents" => ["h"], "signing_mode" => "invalid"}
      assert {:error, {:invalid_signing_mode, "invalid", _}} = WebhookEndpoint.new(params)
    end

    test "rejects invalid rate limit" do
      params = %{"label" => "test", "agents" => ["h"], "rate_limit" => -1}
      assert {:error, {:invalid_rate_limit, -1, _}} = WebhookEndpoint.new(params)
    end
  end

  describe "rotate_secret/1" do
    test "generates new secret and stores previous" do
      {:ok, endpoint} = WebhookEndpoint.new(%{"label" => "test", "agents" => ["a"]})
      original_secret = endpoint.signing_secret

      rotated = WebhookEndpoint.rotate_secret(endpoint)

      assert rotated.signing_secret != original_secret
      assert rotated.previous_secret == original_secret
      refute is_nil(rotated.rotated_at)
    end
  end

  describe "rotation_active?/1" do
    test "returns false when no rotation has occurred" do
      {:ok, endpoint} = WebhookEndpoint.new(%{"label" => "test", "agents" => ["a"]})
      refute WebhookEndpoint.rotation_active?(endpoint)
    end

    test "returns true immediately after rotation" do
      {:ok, endpoint} = WebhookEndpoint.new(%{"label" => "test", "agents" => ["a"]})
      rotated = WebhookEndpoint.rotate_secret(endpoint)
      assert WebhookEndpoint.rotation_active?(rotated)
    end
  end

  describe "to_map/1 and from_map/1 roundtrip" do
    test "serializes and deserializes correctly" do
      {:ok, original} =
        WebhookEndpoint.new(%{
          "label" => "roundtrip-test",
          "agents" => ["agent-a", "agent-b"],
          "signing_mode" => "github",
          "rate_limit" => 30,
          "allowed_ips" => ["10.0.0.1"]
        })

      map = WebhookEndpoint.to_map(original)
      assert {:ok, restored} = WebhookEndpoint.from_map(map)

      assert restored.id == original.id
      assert restored.label == original.label
      assert restored.agents == original.agents
      assert restored.signing_secret == original.signing_secret
      assert restored.signing_mode == original.signing_mode
      assert restored.rate_limit == original.rate_limit
      assert restored.allowed_ips == original.allowed_ips
    end
  end

  describe "to_public_map/1" do
    test "does not include signing_secret" do
      {:ok, endpoint} = WebhookEndpoint.new(%{"label" => "test", "agents" => ["a"]})
      public = WebhookEndpoint.to_public_map(endpoint)

      refute Map.has_key?(public, "signing_secret")
      assert Map.has_key?(public, "id")
      assert Map.has_key?(public, "label")
      assert Map.has_key?(public, "rotation_active")
    end
  end

  describe "generate_id/0" do
    test "generates unique IDs with prefix" do
      id1 = WebhookEndpoint.generate_id()
      id2 = WebhookEndpoint.generate_id()

      assert String.starts_with?(id1, "whk_")
      assert String.starts_with?(id2, "whk_")
      assert id1 != id2
    end
  end

  describe "generate_secret/0" do
    test "generates 64-char hex string" do
      secret = WebhookEndpoint.generate_secret()
      assert byte_size(secret) == 64
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, secret)
    end
  end
end
