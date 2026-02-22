defmodule TriOnyx.WebhookReceiver do
  @moduledoc """
  Handles incoming webhook requests on the `/hooks/:endpoint_id` path.

  This module implements the full ingress pipeline:

  1. Endpoint lookup (ETS — no GenServer bottleneck)
  2. Enabled check
  3. IP allowlist check
  4. Rate limiting
  5. HMAC signature verification (provider-specific)
  6. Payload validation (size + JSON)
  7. Fan-out dispatch to all bound agents via TriggerRouter
  8. Audit logging

  Called by the main Router plug. Returns `{status_code, response_body}`.

  ## Security Properties

  - Unknown endpoint IDs return 404 with constant-time behavior (dummy HMAC
    computed before returning to prevent timing-based enumeration)
  - All signature comparisons are constant-time
  - Webhook payloads always taint the receiving agent session
  """

  require Logger

  alias TriOnyx.AuditLog
  alias TriOnyx.TriggerRouter
  alias TriOnyx.WebhookEndpoint
  alias TriOnyx.WebhookRateLimiter
  alias TriOnyx.WebhookRegistry
  alias TriOnyx.WebhookSignature

  @max_payload_bytes 1_048_576

  @doc """
  Handles an incoming webhook request.

  ## Parameters

  - `endpoint_id` — the endpoint ID from the URL path
  - `body` — the raw request body
  - `headers` — list of `{name, value}` header tuples (lowercased names)
  - `source_ip` — the remote IP address as a string
  - `opts` — optional overrides for testing:
    - `:registry_table` — ETS table for endpoint lookup
    - `:rate_limiter_table` — ETS table for rate limiting
    - `:router` — TriggerRouter process name/pid
  """
  @spec handle(String.t(), String.t(), [{String.t(), String.t()}], String.t(), keyword()) ::
          {pos_integer(), map()}
  def handle(endpoint_id, body, headers, source_ip, opts \\ []) do
    registry_table = Keyword.get(opts, :registry_table, :webhook_endpoints)
    rate_limiter_table = Keyword.get(opts, :rate_limiter_table, :webhook_rate_limits)
    router = Keyword.get(opts, :router, TriggerRouter)

    case WebhookRegistry.lookup(endpoint_id, registry_table) do
      {:ok, endpoint} ->
        process_webhook(endpoint, body, headers, source_ip, rate_limiter_table, router)

      :error ->
        # Constant-time: compute a dummy HMAC to prevent timing-based enumeration
        dummy_secret = "0000000000000000000000000000000000000000000000000000000000000000"
        _ = :crypto.mac(:hmac, :sha256, dummy_secret, body)

        log_delivery(endpoint_id, nil, source_ip, 404, "unknown_endpoint")
        {404, %{"error" => "not_found"}}
    end
  end

  # --- Private Pipeline ---

  @spec process_webhook(
          WebhookEndpoint.t(),
          String.t(),
          [{String.t(), String.t()}],
          String.t(),
          atom(),
          GenServer.server()
        ) :: {pos_integer(), map()}
  defp process_webhook(endpoint, body, headers, source_ip, rate_table, router) do
    with :ok <- check_enabled(endpoint),
         :ok <- check_ip_allowlist(endpoint, source_ip),
         :ok <- check_rate_limit(endpoint, source_ip, rate_table),
         :ok <- check_payload_size(body),
         :ok <- verify_signature(endpoint, body, headers),
         {:ok, _parsed} <- parse_json(body) do
      dispatch_to_agents(endpoint, body, source_ip, router)
    else
      {:error, :disabled} ->
        log_delivery(endpoint.id, endpoint.label, source_ip, 404, "endpoint_disabled")
        # Return 404 to avoid revealing that the endpoint exists but is disabled
        {404, %{"error" => "not_found"}}

      {:error, :ip_not_allowed} ->
        log_delivery(endpoint.id, endpoint.label, source_ip, 403, "ip_not_allowed")
        {403, %{"error" => "forbidden"}}

      {:error, :rate_limited, retry_after} ->
        log_delivery(endpoint.id, endpoint.label, source_ip, 429, "rate_limited")
        {429, %{"error" => "rate_limited", "retry_after" => retry_after}}

      {:error, :payload_too_large} ->
        log_delivery(endpoint.id, endpoint.label, source_ip, 413, "payload_too_large")
        {413, %{"error" => "payload_too_large", "max_bytes" => @max_payload_bytes}}

      {:error, sig_reason}
      when sig_reason in [
             :missing_signature,
             :missing_timestamp,
             :invalid_timestamp,
             :timestamp_expired,
             :signature_mismatch,
             :invalid_signature_format
           ] ->
        log_delivery(endpoint.id, endpoint.label, source_ip, 401, to_string(sig_reason))
        {401, %{"error" => "unauthorized", "reason" => to_string(sig_reason)}}

      {:error, :invalid_json} ->
        log_delivery(endpoint.id, endpoint.label, source_ip, 400, "invalid_json")
        {400, %{"error" => "invalid_json"}}
    end
  end

  @spec check_enabled(WebhookEndpoint.t()) :: :ok | {:error, :disabled}
  defp check_enabled(%{enabled: true}), do: :ok
  defp check_enabled(%{enabled: false}), do: {:error, :disabled}

  @spec check_ip_allowlist(WebhookEndpoint.t(), String.t()) :: :ok | {:error, :ip_not_allowed}
  defp check_ip_allowlist(%{allowed_ips: nil}, _source_ip), do: :ok

  defp check_ip_allowlist(%{allowed_ips: allowed_ips}, source_ip) do
    if ip_matches?(source_ip, allowed_ips) do
      :ok
    else
      {:error, :ip_not_allowed}
    end
  end

  @spec check_rate_limit(WebhookEndpoint.t(), String.t(), atom()) ::
          :ok | {:error, :rate_limited, non_neg_integer()}
  defp check_rate_limit(endpoint, source_ip, rate_table) do
    WebhookRateLimiter.check_rate(endpoint.id, source_ip, endpoint.rate_limit, rate_table)
  end

  @spec check_payload_size(String.t()) :: :ok | {:error, :payload_too_large}
  defp check_payload_size(body) when byte_size(body) > @max_payload_bytes do
    {:error, :payload_too_large}
  end

  defp check_payload_size(_body), do: :ok

  @spec verify_signature(WebhookEndpoint.t(), binary(), [{String.t(), String.t()}]) ::
          :ok | {:error, term()}
  defp verify_signature(endpoint, body, headers) do
    case WebhookSignature.verify(endpoint.signing_mode, endpoint.signing_secret, body, headers) do
      :ok ->
        :ok

      {:error, _reason} = error ->
        # If rotation is active, try the previous secret
        if endpoint.previous_secret && WebhookEndpoint.rotation_active?(endpoint) do
          case WebhookSignature.verify(
                 endpoint.signing_mode,
                 endpoint.previous_secret,
                 body,
                 headers
               ) do
            :ok -> :ok
            {:error, _} -> error
          end
        else
          error
        end
    end
  end

  @spec parse_json(String.t()) :: {:ok, term()} | {:error, :invalid_json}
  defp parse_json(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _} -> {:error, :invalid_json}
    end
  end

  @spec dispatch_to_agents(WebhookEndpoint.t(), String.t(), String.t(), GenServer.server()) ::
          {pos_integer(), map()}
  defp dispatch_to_agents(endpoint, body, source_ip, router) do
    results =
      Enum.map(endpoint.agents, fn agent_name ->
        event = %{
          type: :webhook,
          agent_name: agent_name,
          payload: body,
          metadata: %{
            endpoint_id: endpoint.id,
            endpoint_label: endpoint.label,
            signing_mode: to_string(endpoint.signing_mode),
            source_ip: source_ip,
            received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            content_type: "application/json"
          }
        }

        case TriggerRouter.dispatch(router, event) do
          {:ok, _pid} ->
            Logger.info(
              "WebhookReceiver: dispatched #{endpoint.id} to agent '#{agent_name}'"
            )

            {:ok, agent_name}

          {:error, reason} ->
            Logger.error(
              "WebhookReceiver: dispatch to '#{agent_name}' failed: #{inspect(reason)}"
            )

            {:error, agent_name, reason}
        end
      end)

    successful = Enum.filter(results, &match?({:ok, _}, &1))
    failed = Enum.filter(results, &match?({:error, _, _}, &1))

    log_delivery(endpoint.id, endpoint.label, source_ip, 202, "dispatched")

    cond do
      length(failed) == 0 ->
        {202,
         %{
           "status" => "accepted",
           "endpoint" => endpoint.id,
           "agents" => Enum.map(successful, fn {:ok, name} -> name end)
         }}

      length(successful) > 0 ->
        {202,
         %{
           "status" => "partial",
           "endpoint" => endpoint.id,
           "agents" => Enum.map(successful, fn {:ok, name} -> name end),
           "failed" => Enum.map(failed, fn {:error, name, _} -> name end)
         }}

      true ->
        {500, %{"error" => "dispatch_failed", "endpoint" => endpoint.id}}
    end
  end

  @spec ip_matches?(String.t(), [String.t()]) :: boolean()
  defp ip_matches?(source_ip, allowed_ips) do
    Enum.any?(allowed_ips, fn allowed ->
      if String.contains?(allowed, "/") do
        cidr_match?(source_ip, allowed)
      else
        source_ip == allowed
      end
    end)
  end

  @spec cidr_match?(String.t(), String.t()) :: boolean()
  defp cidr_match?(ip_str, cidr_str) do
    with [network_str, mask_str] <- String.split(cidr_str, "/", parts: 2),
         {mask_bits, ""} <- Integer.parse(mask_str),
         {:ok, ip} <- parse_ip(ip_str),
         {:ok, network} <- parse_ip(network_str) do
      ip_int = ip_to_integer(ip)
      network_int = ip_to_integer(network)
      bit_length = if tuple_size(ip) == 4, do: 32, else: 128
      shift = bit_length - mask_bits

      Bitwise.bsr(ip_int, shift) == Bitwise.bsr(network_int, shift)
    else
      _ -> false
    end
  end

  @spec parse_ip(String.t()) :: {:ok, :inet.ip_address()} | :error
  defp parse_ip(ip_str) do
    case :inet.parse_address(String.to_charlist(ip_str)) do
      {:ok, ip} -> {:ok, ip}
      {:error, _} -> :error
    end
  end

  @spec ip_to_integer(:inet.ip_address()) :: non_neg_integer()
  defp ip_to_integer({a, b, c, d}) do
    Bitwise.bsl(a, 24) + Bitwise.bsl(b, 16) + Bitwise.bsl(c, 8) + d
  end

  defp ip_to_integer({a, b, c, d, e, f, g, h}) do
    Bitwise.bsl(a, 112) + Bitwise.bsl(b, 96) + Bitwise.bsl(c, 80) + Bitwise.bsl(d, 64) +
      Bitwise.bsl(e, 48) + Bitwise.bsl(f, 32) + Bitwise.bsl(g, 16) + h
  end

  @spec log_delivery(
          String.t(),
          String.t() | nil,
          String.t(),
          pos_integer(),
          String.t()
        ) :: :ok
  defp log_delivery(endpoint_id, label, source_ip, status, outcome) do
    AuditLog.log_event(%{
      type: :webhook_delivery,
      endpoint_id: endpoint_id,
      endpoint_label: label,
      source_ip: source_ip,
      http_status: status,
      outcome: outcome
    })
  end
end
