defmodule TriOnyx.Triggers.Webhook do
  @moduledoc """
  Plug handler for webhook trigger endpoints.

  Handles `POST /webhooks/:agent_name` requests. Webhook payloads are
  untrusted by definition — the agent session is immediately tainted when
  a webhook trigger is dispatched.

  Validates that:
  - The request body is valid JSON
  - The target agent exists in the trigger router
  - The payload is within size limits

  Future: schema validation against agent-specific payload schemas.
  """

  require Logger

  @max_payload_bytes 1_048_576

  @doc """
  Handles a webhook request for the given agent name.

  Called by the main Router plug. Expects the request body to be a JSON
  object. Returns `{status_code, response_body}`.
  """
  @spec handle(String.t(), String.t(), GenServer.server()) ::
          {pos_integer(), map()}
  def handle(agent_name, body, router \\ TriOnyx.TriggerRouter) do
    with :ok <- validate_payload_size(body),
         {:ok, _parsed} <- parse_json(body) do
      event = %{
        type: :webhook,
        agent_name: agent_name,
        payload: body,
        metadata: %{
          received_at: DateTime.utc_now() |> DateTime.to_iso8601(),
          content_type: "application/json"
        }
      }

      case TriOnyx.TriggerRouter.dispatch(router, event) do
        {:ok, _pid} ->
          Logger.info("Webhook: dispatched to agent '#{agent_name}'")
          {202, %{"status" => "accepted", "agent" => agent_name}}

        {:error, {:unknown_agent, _name}} ->
          Logger.warning("Webhook: unknown agent '#{agent_name}'")
          {404, %{"error" => "unknown_agent", "agent" => agent_name}}

        {:error, reason} ->
          Logger.error("Webhook: dispatch failed for '#{agent_name}': #{inspect(reason)}")
          {500, %{"error" => "dispatch_failed"}}
      end
    else
      {:error, :payload_too_large} ->
        {413, %{"error" => "payload_too_large", "max_bytes" => @max_payload_bytes}}

      {:error, :invalid_json} ->
        {400, %{"error" => "invalid_json"}}
    end
  end

  @spec validate_payload_size(String.t()) :: :ok | {:error, :payload_too_large}
  defp validate_payload_size(body) when byte_size(body) > @max_payload_bytes do
    {:error, :payload_too_large}
  end

  defp validate_payload_size(_body), do: :ok

  @spec parse_json(String.t()) :: {:ok, term()} | {:error, :invalid_json}
  defp parse_json(body) do
    case Jason.decode(body) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end
end
