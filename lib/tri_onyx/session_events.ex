defmodule TriOnyx.SessionEvents do
  @moduledoc """
  Canonical registry of session event types.

  `AgentSession` emits events as string literals; this module is the
  single list consumers key on. It is served via `GET /agents/schema`
  as `session_events` so the frontend never hardcodes event-type lists,
  and a consistency test asserts it stays in lockstep with the literals
  in `agent_session.ex`.
  """

  # Every event type AgentSession logs or broadcasts.
  @event_types ~w(
    agent_log approval_request audio bcp_query bcp_response
    bcp_subscription_publish calendar_create calendar_delete
    calendar_query calendar_update create_folder error github_command
    heartbeat_notification heartbeat_result idle_timeout image
    interrupted move_email page port_down ready restart_agent result
    risk_escalation send_email send_message session_killed
    session_start session_stop text tool_use tool_result user_prompt
  )

  # The subset the chat UI displays (history rendering and live SSE).
  # Other types are internal plumbing (BCP delivery, email/calendar
  # request forwarding, heartbeat fan-out) with no chat representation.
  @chat_visible ~w(
    approval_request audio bcp_query error idle_timeout image interrupted
    page port_down ready result risk_escalation send_message
    session_start session_stop text tool_use tool_result user_prompt
  )

  # Stream-level events synthesized by the router's SSE endpoint
  # (never logged; they describe the stream, not the session).
  @sse_meta_types ~w(connected waiting)

  @doc "All session event types AgentSession can emit."
  @spec event_types() :: [String.t()]
  def event_types, do: @event_types

  @doc "Event types the chat UI renders."
  @spec chat_visible() :: [String.t()]
  def chat_visible, do: @chat_visible

  @doc "SSE stream meta event types synthesized by the router."
  @spec sse_meta_types() :: [String.t()]
  def sse_meta_types, do: @sse_meta_types
end
