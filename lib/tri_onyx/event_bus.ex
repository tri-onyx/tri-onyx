defmodule TriOnyx.EventBus do
  @moduledoc """
  Pub/sub event bus for streaming agent session events to SSE clients.

  Uses a Registry in `:duplicate` mode so multiple subscribers (browser tabs,
  API consumers) can listen to the same session. Subscribers receive plain
  maps that are safe to encode as JSON and push over Server-Sent Events.
  """

  @registry TriOnyx.EventBus.Registry

  @doc """
  Subscribes the calling process to events for `session_id`.

  The subscriber will receive messages of the form:

      {:event_bus, session_id, event_map}
  """
  @spec subscribe(String.t()) :: {:ok, pid()} | {:error, term()}
  def subscribe(session_id) do
    Registry.register(@registry, session_id, [])
  end

  @doc """
  Subscribes the calling process to agent-level events (keyed by `"agent:<name>"`).

  Used by SSE connections that open before a session exists. When a session
  starts, `broadcast_agent/2` delivers the session_id so the subscriber can
  transition to session-level events.
  """
  @spec subscribe_agent(String.t()) :: {:ok, pid()} | {:error, term()}
  def subscribe_agent(agent_name) do
    Registry.register(@registry, "agent:#{agent_name}", [])
  end

  @doc """
  Broadcasts an event map to all subscribers of `session_id`.

  `event` should be a JSON-serialisable map, e.g.:

      %{"type" => "text", "content" => "Hello"}
  """
  @spec broadcast(String.t(), map()) :: :ok
  def broadcast(session_id, %{} = event) do
    Registry.dispatch(@registry, session_id, fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:event_bus, session_id, event})
      end
    end)
  end

  @doc """
  Broadcasts an event to agent-level subscribers (those waiting for a session to start).
  """
  @spec broadcast_agent(String.t(), map()) :: :ok
  def broadcast_agent(agent_name, %{} = event) do
    Registry.dispatch(@registry, "agent:#{agent_name}", fn entries ->
      for {pid, _value} <- entries do
        send(pid, {:event_bus_agent, agent_name, event})
      end
    end)
  end
end
