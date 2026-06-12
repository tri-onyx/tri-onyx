defmodule TriOnyx.SessionEventsConsistencyTest do
  @moduledoc """
  AgentSession emits events as string literals; SessionEvents is the
  registry consumers (and the schema endpoint) key on. These tests turn
  drift between the two into failures.
  """
  use ExUnit.Case, async: true

  alias TriOnyx.SessionEvents

  test "registry matches the event literals emitted by AgentSession" do
    literals =
      "lib/tri_onyx/agent_session.ex"
      |> File.read!()
      |> then(&Regex.scan(~r/"type" => "(\w+)"/, &1))
      |> Enum.map(fn [_, type] -> type end)
      |> Enum.uniq()
      |> Enum.sort()

    registered = Enum.sort(SessionEvents.event_types())

    assert literals == registered,
           "SessionEvents registry out of sync with agent_session.ex — " <>
             "missing from registry: #{inspect(literals -- registered)}, " <>
             "stale in registry: #{inspect(registered -- literals)}"
  end

  test "chat-visible types are a subset of all event types" do
    assert SessionEvents.chat_visible() -- SessionEvents.event_types() == []
  end

  test "router synthesizes exactly the registered SSE meta events" do
    literals =
      "lib/tri_onyx/router.ex"
      |> File.read!()
      |> then(&Regex.scan(~r/sse_encode\("(\w+)"/, &1))
      |> Enum.map(fn [_, type] -> type end)
      |> Enum.uniq()

    meta = Enum.reject(literals, &(&1 in SessionEvents.event_types()))

    assert Enum.sort(meta) == Enum.sort(SessionEvents.sse_meta_types())
  end
end
