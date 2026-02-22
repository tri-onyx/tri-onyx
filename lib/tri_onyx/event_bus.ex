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
end
