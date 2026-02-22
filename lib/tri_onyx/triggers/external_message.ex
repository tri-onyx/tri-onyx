defmodule TriOnyx.Triggers.ExternalMessage do
  @moduledoc """
  Plug handler for external message trigger endpoints.

  Handles `POST /messages` requests. External messages are trusted after
  sender verification — the agent session remains clean.

  Sender verification is performed via API key authentication. The API key
  must be provided in the `Authorization` header as a Bearer token.

  Future: support for signature-based and token-based verification.
  """

  require Logger

  @doc """
  Handles an external message request.

  Called by the main Router plug. Expects a JSON body with:
  - `"agent"` — target agent name (required)
  - `"content"` — message content (required)
  - `"sender"` — sender identifier (optional, for audit)

  The `api_key` parameter is the Bearer token extracted from the
  Authorization header.

  Returns `{status_code, response_body}`.
  """
  @spec handle(String.t(), String.t() | nil, GenServer.server()) ::
          {pos_integer(), map()}
  def handle(body, api_key, router \\ TriOnyx.TriggerRouter) do
    with {:ok, parsed} <- parse_body(body),
         :ok <- verify_sender(api_key),
         {:ok, agent_name} <- extract_field(parsed, "agent"),
         {:ok, content} <- extract_field(parsed, "content") do
      sender = Map.get(parsed, "sender", "anonymous")

      event = %{
        type: :external_message,
        agent_name: agent_name,
        payload: content,
        metadata: %{
          sender: sender,
          received_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }
      }

      case TriOnyx.TriggerRouter.dispatch(router, event) do
        {:ok, _pid} ->
          Logger.info("ExternalMessage: dispatched to agent '#{agent_name}' from '#{sender}'")
          {202, %{"status" => "accepted", "agent" => agent_name}}

        {:error, {:unknown_agent, _name}} ->
          {404, %{"error" => "unknown_agent", "agent" => agent_name}}

        {:error, reason} ->
          Logger.error("ExternalMessage: dispatch failed: #{inspect(reason)}")
          {500, %{"error" => "dispatch_failed"}}
      end
    else
      {:error, :invalid_json} ->
        {400, %{"error" => "invalid_json"}}

      {:error, :unauthorized} ->
        {401, %{"error" => "unauthorized"}}

      {:error, {:missing_field, field}} ->
        {400, %{"error" => "missing_field", "field" => field}}
    end
  end

  @spec parse_body(String.t()) :: {:ok, map()} | {:error, :invalid_json}
  defp parse_body(body) do
    case Jason.decode(body) do
      {:ok, parsed} when is_map(parsed) -> {:ok, parsed}
      _ -> {:error, :invalid_json}
    end
  end

  @spec verify_sender(String.t() | nil) :: :ok | {:error, :unauthorized}
  defp verify_sender(nil), do: {:error, :unauthorized}
  defp verify_sender(""), do: {:error, :unauthorized}

  defp verify_sender(api_key) when is_binary(api_key) do
    configured_key = Application.get_env(:tri_onyx, :api_key)

    cond do
      is_nil(configured_key) ->
        # No API key configured — accept all requests in development
        Logger.warning("ExternalMessage: no API key configured, accepting request")
        :ok

      secure_compare(api_key, configured_key) ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  @spec extract_field(map(), String.t()) :: {:ok, String.t()} | {:error, {:missing_field, String.t()}}
  defp extract_field(parsed, field) do
    case Map.get(parsed, field) do
      nil -> {:error, {:missing_field, field}}
      value when is_binary(value) -> {:ok, value}
      _other -> {:error, {:missing_field, field}}
    end
  end

  # Constant-time string comparison to prevent timing attacks
  @spec secure_compare(String.t(), String.t()) :: boolean()
  defp secure_compare(a, b) when is_binary(a) and is_binary(b) do
    byte_size(a) == byte_size(b) and :crypto.hash_equals(a, b)
  end
end
