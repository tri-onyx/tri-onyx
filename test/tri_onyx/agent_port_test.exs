defmodule TriOnyx.AgentPortTest do
  use ExUnit.Case, async: true

  alias TriOnyx.AgentPort

  # The port's stdout carries everything the container writes (stderr is
  # merged in via :stderr_to_stdout), and any process inside the sandbox
  # running as the agent user can write to it. These tests drive
  # handle_info/2 directly with a stand-in port reference — no subprocess.

  defp state do
    port = make_ref()
    {port, %AgentPort{port: port, notify: self(), buffer: "", container_name: nil}}
  end

  defp feed(port, state, data) do
    {:noreply, state} = AgentPort.handle_info({port, {:data, data}}, state)
    state
  end

  describe "stdout line framing" do
    test "frames split across chunks are reassembled" do
      {port, s} = state()

      s = feed(port, s, ~s({"type":))
      s = feed(port, s, ~s("ready"}\n{"type":"rea))
      assert_receive {:agent_event, _, {:ready}}
      refute_received {:agent_event, _, _}

      s = feed(port, s, ~s(dy"}\n))
      assert_receive {:agent_event, _, {:ready}}
      assert s.buffer == ""
    end

    test "a newline-free stream from the sandbox does not grow gateway memory without bound" do
      {port, s} = state()
      chunk = :binary.copy("A", 16 * 1024 * 1024)

      s = Enum.reduce(1..4, s, fn _, acc -> feed(port, acc, chunk) end)

      assert byte_size(s.buffer) <= 32 * 1024 * 1024,
             "AgentPort buffered #{byte_size(s.buffer)} bytes of an unterminated line; " <>
               "a sandboxed agent writing to the runner's stdout/stderr must not be able " <>
               "to grow gateway memory without limit"

      # The rest of the oversized line is dropped up to its newline; framing
      # resumes on the next line.
      s = feed(port, s, ~s(AAAA","type":"ready"}\n{"type":"ready"}\n))
      assert_receive {:agent_event, _, {:ready}}
      refute_received {:agent_event, _, _}
      assert s.buffer == ""
    end
  end
end
