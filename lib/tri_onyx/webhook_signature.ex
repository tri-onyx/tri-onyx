defmodule TriOnyx.WebhookSignature do
  @moduledoc """
  HMAC signature verification for incoming webhook requests.

  Supports multiple signing schemes used by common webhook providers:

  - `:default` — TriOnyx scheme: HMAC-SHA256 over `timestamp.body`,
    sent in `X-Webhook-Signature` header with timestamp in
    `X-Webhook-Timestamp` header. Includes replay protection.
  - `:github` — GitHub scheme: HMAC-SHA256 over the raw body,
    sent in `X-Hub-Signature-256` as `sha256=<hex>`.
  - `:stripe` — Stripe scheme: HMAC-SHA256 over `timestamp.body`,
    parsed from the `Stripe-Signature` header's `t=` and `v1=` fields.
  - `:slack` — Slack scheme: HMAC-SHA256 over `v0:timestamp:body`,
    sent in `X-Slack-Signature` as `v0=<hex>` with timestamp in
    `X-Slack-Request-Timestamp`.
  - `:none` — no verification (path token is sole auth).

  All comparisons use constant-time comparison via `:crypto.hash_equals/2`.
  """

  @replay_window_seconds 300

  @type signing_mode :: :default | :github | :stripe | :slack | :none
  @type verify_result :: :ok | {:error, reason()}
  @type reason ::
          :missing_signature
          | :missing_timestamp
          | :invalid_timestamp
          | :timestamp_expired
          | :signature_mismatch
          | :invalid_signature_format

  @doc """
  Verifies the webhook signature for the given signing mode.

  ## Parameters

  - `mode` — the signing scheme to use
  - `secret` — the HMAC signing secret (hex-encoded for default/github/stripe/slack)
  - `raw_body` — the raw request body as a binary
  - `headers` — list of `{header_name, header_value}` tuples (lowercased names)

  Returns `:ok` on success or `{:error, reason}` on failure.
  """
  @spec verify(signing_mode(), String.t(), binary(), [{String.t(), String.t()}]) :: verify_result()
  def verify(:none, _secret, _body, _headers), do: :ok

  def verify(:default, secret, body, headers) do
    verify_default(secret, body, headers)
  end

  def verify(:github, secret, body, headers) do
    verify_github(secret, body, headers)
  end

  def verify(:stripe, secret, body, headers) do
    verify_stripe(secret, body, headers)
  end

  def verify(:slack, secret, body, headers) do
    verify_slack(secret, body, headers)
  end

  @doc """
  Computes the HMAC-SHA256 signature for the TriOnyx default scheme.

  Used by callers to generate the expected headers when sending webhooks.
  Returns `{signature_hex, timestamp_string}`.
  """
  @spec sign_default(String.t(), binary()) :: {String.t(), String.t()}
  def sign_default(secret, body) do
    timestamp = Integer.to_string(System.system_time(:second))
    signed_payload = timestamp <> "." <> body
    signature = compute_hmac(secret, signed_payload)
    {"sha256=" <> signature, timestamp}
  end

  @doc """
  Computes the HMAC-SHA256 signature for the GitHub scheme.
  """
  @spec sign_github(String.t(), binary()) :: String.t()
  def sign_github(secret, body) do
    "sha256=" <> compute_hmac(secret, body)
  end

  # --- Default Scheme ---

  @spec verify_default(String.t(), binary(), [{String.t(), String.t()}]) :: verify_result()
  defp verify_default(secret, body, headers) do
    with {:sig, {:ok, signature}} <- {:sig, get_header(headers, "x-webhook-signature")},
         {:ts, {:ok, timestamp_str}} <- {:ts, get_header(headers, "x-webhook-timestamp")},
         :ok <- validate_timestamp(timestamp_str),
         {:ok, received_hex} <- parse_sha256_prefix(signature) do
      signed_payload = timestamp_str <> "." <> body
      expected = compute_hmac(secret, signed_payload)
      constant_time_compare(received_hex, expected)
    else
      {:sig, {:error, :header_not_found}} -> {:error, :missing_signature}
      {:ts, {:error, :header_not_found}} -> {:error, :missing_timestamp}
      error -> error
    end
  end

  # --- GitHub Scheme ---

  @spec verify_github(String.t(), binary(), [{String.t(), String.t()}]) :: verify_result()
  defp verify_github(secret, body, headers) do
    with {:ok, signature} <- get_header(headers, "x-hub-signature-256"),
         {:ok, received_hex} <- parse_sha256_prefix(signature) do
      expected = compute_hmac(secret, body)
      constant_time_compare(received_hex, expected)
    else
      {:error, :header_not_found} -> {:error, :missing_signature}
      error -> error
    end
  end

  # --- Stripe Scheme ---

  @spec verify_stripe(String.t(), binary(), [{String.t(), String.t()}]) :: verify_result()
  defp verify_stripe(secret, body, headers) do
    with {:ok, sig_header} <- get_header(headers, "stripe-signature"),
         {:ok, timestamp_str, received_hex} <- parse_stripe_signature(sig_header),
         :ok <- validate_timestamp(timestamp_str) do
      signed_payload = timestamp_str <> "." <> body
      expected = compute_hmac(secret, signed_payload)
      constant_time_compare(received_hex, expected)
    else
      {:error, :header_not_found} -> {:error, :missing_signature}
      error -> error
    end
  end

  # --- Slack Scheme ---

  @spec verify_slack(String.t(), binary(), [{String.t(), String.t()}]) :: verify_result()
  defp verify_slack(secret, body, headers) do
    with {:sig, {:ok, signature}} <- {:sig, get_header(headers, "x-slack-signature")},
         {:ts, {:ok, timestamp_str}} <- {:ts, get_header(headers, "x-slack-request-timestamp")},
         :ok <- validate_timestamp(timestamp_str),
         {:ok, received_hex} <- parse_v0_prefix(signature) do
      sig_basestring = "v0:" <> timestamp_str <> ":" <> body
      expected = compute_hmac(secret, sig_basestring)
      constant_time_compare(received_hex, expected)
    else
      {:sig, {:error, :header_not_found}} -> {:error, :missing_signature}
      {:ts, {:error, :header_not_found}} -> {:error, :missing_timestamp}
      error -> error
    end
  end

  # --- Helpers ---

  @spec compute_hmac(String.t(), binary()) :: String.t()
  defp compute_hmac(secret, payload) do
    :crypto.mac(:hmac, :sha256, secret, payload)
    |> Base.encode16(case: :lower)
  end

  @spec constant_time_compare(String.t(), String.t()) :: :ok | {:error, :signature_mismatch}
  defp constant_time_compare(a, b) when is_binary(a) and is_binary(b) do
    if byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b) do
      :ok
    else
      {:error, :signature_mismatch}
    end
  end

  @spec get_header([{String.t(), String.t()}], String.t()) ::
          {:ok, String.t()} | {:error, :header_not_found}
  defp get_header(headers, name) do
    case List.keyfind(headers, name, 0) do
      {^name, value} -> {:ok, value}
      nil -> {:error, :header_not_found}
    end
  end

  @spec validate_timestamp(String.t()) :: :ok | {:error, :invalid_timestamp | :timestamp_expired}
  defp validate_timestamp(timestamp_str) do
    case Integer.parse(timestamp_str) do
      {ts, ""} ->
        now = System.system_time(:second)
        diff = abs(now - ts)

        if diff <= @replay_window_seconds do
          :ok
        else
          {:error, :timestamp_expired}
        end

      _ ->
        {:error, :invalid_timestamp}
    end
  end

  @spec parse_sha256_prefix(String.t()) :: {:ok, String.t()} | {:error, :invalid_signature_format}
  defp parse_sha256_prefix("sha256=" <> hex), do: {:ok, hex}
  defp parse_sha256_prefix(_), do: {:error, :invalid_signature_format}

  @spec parse_v0_prefix(String.t()) :: {:ok, String.t()} | {:error, :invalid_signature_format}
  defp parse_v0_prefix("v0=" <> hex), do: {:ok, hex}
  defp parse_v0_prefix(_), do: {:error, :invalid_signature_format}

  @spec parse_stripe_signature(String.t()) ::
          {:ok, String.t(), String.t()} | {:error, :invalid_signature_format}
  defp parse_stripe_signature(header) do
    parts =
      header
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.map(fn part ->
        case String.split(part, "=", parts: 2) do
          [key, value] -> {key, value}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Map.new()

    case {Map.get(parts, "t"), Map.get(parts, "v1")} do
      {timestamp, signature} when is_binary(timestamp) and is_binary(signature) ->
        {:ok, timestamp, signature}

      _ ->
        {:error, :invalid_signature_format}
    end
  end
end
