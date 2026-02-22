defmodule TriOnyx.WebhookSignatureTest do
  use ExUnit.Case

  alias TriOnyx.WebhookSignature

  @secret "test-secret-key-for-hmac-verification"
  @body ~s({"event":"push","ref":"refs/heads/main"})

  describe "verify/4 with :none mode" do
    test "always passes" do
      assert :ok = WebhookSignature.verify(:none, @secret, @body, [])
    end
  end

  describe "verify/4 with :default mode" do
    test "accepts valid signature with current timestamp" do
      {signature, timestamp} = WebhookSignature.sign_default(@secret, @body)

      headers = [
        {"x-webhook-signature", signature},
        {"x-webhook-timestamp", timestamp}
      ]

      assert :ok = WebhookSignature.verify(:default, @secret, @body, headers)
    end

    test "rejects missing signature header" do
      headers = [{"x-webhook-timestamp", "1739577600"}]
      assert {:error, :missing_signature} = WebhookSignature.verify(:default, @secret, @body, headers)
    end

    test "rejects missing timestamp header" do
      headers = [{"x-webhook-signature", "sha256=abcdef"}]
      assert {:error, :missing_timestamp} = WebhookSignature.verify(:default, @secret, @body, headers)
    end

    test "rejects expired timestamp" do
      # Use a timestamp from 10 minutes ago
      old_timestamp = Integer.to_string(System.system_time(:second) - 600)
      signed_payload = old_timestamp <> "." <> @body
      mac = :crypto.mac(:hmac, :sha256, @secret, signed_payload) |> Base.encode16(case: :lower)

      headers = [
        {"x-webhook-signature", "sha256=" <> mac},
        {"x-webhook-timestamp", old_timestamp}
      ]

      assert {:error, :timestamp_expired} = WebhookSignature.verify(:default, @secret, @body, headers)
    end

    test "rejects tampered body" do
      {signature, timestamp} = WebhookSignature.sign_default(@secret, @body)

      headers = [
        {"x-webhook-signature", signature},
        {"x-webhook-timestamp", timestamp}
      ]

      tampered_body = ~s({"event":"push","ref":"refs/heads/evil"})
      assert {:error, :signature_mismatch} = WebhookSignature.verify(:default, @secret, tampered_body, headers)
    end

    test "rejects wrong secret" do
      {signature, timestamp} = WebhookSignature.sign_default(@secret, @body)

      headers = [
        {"x-webhook-signature", signature},
        {"x-webhook-timestamp", timestamp}
      ]

      assert {:error, :signature_mismatch} = WebhookSignature.verify(:default, "wrong-secret", @body, headers)
    end

    test "rejects invalid signature format" do
      timestamp = Integer.to_string(System.system_time(:second))

      headers = [
        {"x-webhook-signature", "md5=abcdef"},
        {"x-webhook-timestamp", timestamp}
      ]

      assert {:error, :invalid_signature_format} = WebhookSignature.verify(:default, @secret, @body, headers)
    end
  end

  describe "verify/4 with :github mode" do
    test "accepts valid GitHub-style signature" do
      signature = WebhookSignature.sign_github(@secret, @body)
      headers = [{"x-hub-signature-256", signature}]

      assert :ok = WebhookSignature.verify(:github, @secret, @body, headers)
    end

    test "rejects missing GitHub signature header" do
      assert {:error, :missing_signature} = WebhookSignature.verify(:github, @secret, @body, [])
    end

    test "rejects invalid GitHub signature" do
      headers = [{"x-hub-signature-256", "sha256=0000000000000000000000000000000000000000000000000000000000000000"}]

      assert {:error, :signature_mismatch} = WebhookSignature.verify(:github, @secret, @body, headers)
    end

    test "rejects tampered body with GitHub signature" do
      signature = WebhookSignature.sign_github(@secret, @body)
      headers = [{"x-hub-signature-256", signature}]

      assert {:error, :signature_mismatch} = WebhookSignature.verify(:github, @secret, "tampered", headers)
    end
  end

  describe "verify/4 with :stripe mode" do
    test "accepts valid Stripe-style signature" do
      timestamp = Integer.to_string(System.system_time(:second))
      signed_payload = timestamp <> "." <> @body
      mac = :crypto.mac(:hmac, :sha256, @secret, signed_payload) |> Base.encode16(case: :lower)

      headers = [{"stripe-signature", "t=#{timestamp},v1=#{mac}"}]

      assert :ok = WebhookSignature.verify(:stripe, @secret, @body, headers)
    end

    test "rejects missing Stripe signature header" do
      assert {:error, :missing_signature} = WebhookSignature.verify(:stripe, @secret, @body, [])
    end

    test "rejects expired Stripe timestamp" do
      old_timestamp = Integer.to_string(System.system_time(:second) - 600)
      signed_payload = old_timestamp <> "." <> @body
      mac = :crypto.mac(:hmac, :sha256, @secret, signed_payload) |> Base.encode16(case: :lower)

      headers = [{"stripe-signature", "t=#{old_timestamp},v1=#{mac}"}]

      assert {:error, :timestamp_expired} = WebhookSignature.verify(:stripe, @secret, @body, headers)
    end
  end

  describe "verify/4 with :slack mode" do
    test "accepts valid Slack-style signature" do
      timestamp = Integer.to_string(System.system_time(:second))
      sig_basestring = "v0:" <> timestamp <> ":" <> @body
      mac = :crypto.mac(:hmac, :sha256, @secret, sig_basestring) |> Base.encode16(case: :lower)

      headers = [
        {"x-slack-signature", "v0=" <> mac},
        {"x-slack-request-timestamp", timestamp}
      ]

      assert :ok = WebhookSignature.verify(:slack, @secret, @body, headers)
    end

    test "rejects missing Slack signature header" do
      headers = [{"x-slack-request-timestamp", "1739577600"}]
      assert {:error, :missing_signature} = WebhookSignature.verify(:slack, @secret, @body, headers)
    end

    test "rejects missing Slack timestamp header" do
      headers = [{"x-slack-signature", "v0=abcdef"}]
      assert {:error, :missing_timestamp} = WebhookSignature.verify(:slack, @secret, @body, headers)
    end
  end

  describe "sign_default/2" do
    test "returns signature and timestamp" do
      {signature, timestamp} = WebhookSignature.sign_default(@secret, @body)

      assert String.starts_with?(signature, "sha256=")
      assert is_binary(timestamp)
      {ts, ""} = Integer.parse(timestamp)
      assert ts > 0
    end
  end

  describe "sign_github/2" do
    test "returns sha256-prefixed signature" do
      signature = WebhookSignature.sign_github(@secret, @body)
      assert String.starts_with?(signature, "sha256=")
      hex = String.replace_prefix(signature, "sha256=", "")
      assert byte_size(hex) == 64
    end
  end
end
