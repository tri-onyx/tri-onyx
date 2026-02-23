defmodule TriOnyx.TaintMatrixTest do
  use ExUnit.Case, async: true

  alias TriOnyx.TaintMatrix

  describe "tool_taint/1" do
    test "web tools are high taint" do
      assert :high = TaintMatrix.tool_taint("WebFetch")
      assert :high = TaintMatrix.tool_taint("WebSearch")
    end

    test "Bash defaults to low taint (no-network default)" do
      assert :low = TaintMatrix.tool_taint("Bash")
    end

    test "Read defaults to low taint (controlled path default)" do
      assert :low = TaintMatrix.tool_taint("Read")
    end

    test "filesystem tools are low taint" do
      assert :low = TaintMatrix.tool_taint("Grep")
      assert :low = TaintMatrix.tool_taint("Glob")
      assert :low = TaintMatrix.tool_taint("Write")
      assert :low = TaintMatrix.tool_taint("Edit")
      assert :low = TaintMatrix.tool_taint("NotebookEdit")
    end

    test "messaging tools are low taint" do
      assert :low = TaintMatrix.tool_taint("SendMessage")
      assert :low = TaintMatrix.tool_taint("BCPQuery")
      assert :low = TaintMatrix.tool_taint("BCPRespond")
    end

    test "control tools are low taint" do
      assert :low = TaintMatrix.tool_taint("RestartAgent")
    end

    test "email tools are low taint" do
      assert :low = TaintMatrix.tool_taint("SendEmail")
      assert :low = TaintMatrix.tool_taint("MoveEmail")
      assert :low = TaintMatrix.tool_taint("CreateFolder")
    end

    test "unknown tools default to low taint" do
      assert :low = TaintMatrix.tool_taint("UnknownTool")
      assert :low = TaintMatrix.tool_taint("ExternalAPITool")
    end
  end

  describe "tool_taint/2 (Read path contexts)" do
    test "Read with controlled context is low taint" do
      assert :low = TaintMatrix.tool_taint("Read", :controlled)
    end

    test "Read with external context is high taint" do
      assert :high = TaintMatrix.tool_taint("Read", :external)
    end

    test "other tools ignore Read context" do
      assert :high = TaintMatrix.tool_taint("WebFetch", :controlled)
    end
  end

  describe "tool_taint/2 (Bash network contexts)" do
    test "Bash with isolated context is low taint" do
      assert :low = TaintMatrix.tool_taint("Bash", :isolated)
    end

    test "Bash with network context is high taint" do
      assert :high = TaintMatrix.tool_taint("Bash", :network)
    end
  end

  describe "trigger_taint/1" do
    test "webhook is high taint" do
      assert :high = TaintMatrix.trigger_taint(:webhook)
    end

    test "unverified_input is high taint" do
      assert :high = TaintMatrix.trigger_taint(:unverified_input)
    end

    test "inter_agent is medium taint" do
      assert :medium = TaintMatrix.trigger_taint(:inter_agent)
    end

    test "trusted triggers are low taint" do
      assert :low = TaintMatrix.trigger_taint(:cron)
      assert :low = TaintMatrix.trigger_taint(:heartbeat)
      assert :low = TaintMatrix.trigger_taint(:external_message)
      assert :low = TaintMatrix.trigger_taint(:verified_input)
    end

    test "unknown triggers default to low taint" do
      assert :low = TaintMatrix.trigger_taint(:some_future_trigger)
    end
  end

  describe "known_tool?/1" do
    test "returns true for registered tools" do
      assert TaintMatrix.known_tool?("Read")
      assert TaintMatrix.known_tool?("Bash")
      assert TaintMatrix.known_tool?("WebFetch")
      assert TaintMatrix.known_tool?("SendEmail")
    end

    test "returns false for unknown tools" do
      refute TaintMatrix.known_tool?("ExternalAPITool")
      refute TaintMatrix.known_tool?("")
    end
  end
end
