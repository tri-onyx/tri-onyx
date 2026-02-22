defmodule TriOnyx.SensitivityMatrixTest do
  use ExUnit.Case, async: true

  alias TriOnyx.SensitivityMatrix

  describe "tool_sensitivity/1" do
    test "email tools are medium sensitivity (auth required)" do
      assert :medium = SensitivityMatrix.tool_sensitivity("SendEmail")
      assert :medium = SensitivityMatrix.tool_sensitivity("MoveEmail")
      assert :medium = SensitivityMatrix.tool_sensitivity("CreateFolder")
    end

    test "filesystem tools are low sensitivity" do
      assert :low = SensitivityMatrix.tool_sensitivity("Read")
      assert :low = SensitivityMatrix.tool_sensitivity("Grep")
      assert :low = SensitivityMatrix.tool_sensitivity("Glob")
      assert :low = SensitivityMatrix.tool_sensitivity("Write")
      assert :low = SensitivityMatrix.tool_sensitivity("Edit")
      assert :low = SensitivityMatrix.tool_sensitivity("NotebookEdit")
    end

    test "execution tools are low sensitivity" do
      assert :low = SensitivityMatrix.tool_sensitivity("Bash")
    end

    test "web tools are low sensitivity" do
      assert :low = SensitivityMatrix.tool_sensitivity("WebFetch")
      assert :low = SensitivityMatrix.tool_sensitivity("WebSearch")
    end

    test "messaging tools are low sensitivity" do
      assert :low = SensitivityMatrix.tool_sensitivity("SendMessage")
      assert :low = SensitivityMatrix.tool_sensitivity("BCTPQuery")
      assert :low = SensitivityMatrix.tool_sensitivity("BCTPRespond")
    end

    test "control tools are low sensitivity" do
      assert :low = SensitivityMatrix.tool_sensitivity("RestartAgent")
    end

    test "unknown tools default to low sensitivity" do
      assert :low = SensitivityMatrix.tool_sensitivity("UnknownTool")
      assert :low = SensitivityMatrix.tool_sensitivity("ExternalAPITool")
    end
  end

  describe "trigger_sensitivity/1" do
    test "most triggers are low sensitivity" do
      assert :low = SensitivityMatrix.trigger_sensitivity(:webhook)
      assert :low = SensitivityMatrix.trigger_sensitivity(:external_message)
      assert :low = SensitivityMatrix.trigger_sensitivity(:connector_verified)
      assert :low = SensitivityMatrix.trigger_sensitivity(:cron)
      assert :low = SensitivityMatrix.trigger_sensitivity(:heartbeat)
    end

    test "connector_unverified has medium sensitivity" do
      assert :medium = SensitivityMatrix.trigger_sensitivity(:connector_unverified)
    end

    test "unknown triggers default to low sensitivity" do
      assert :low = SensitivityMatrix.trigger_sensitivity(:some_future_trigger)
    end
  end

  describe "known_tool?/1" do
    test "returns true for registered tools" do
      assert SensitivityMatrix.known_tool?("Read")
      assert SensitivityMatrix.known_tool?("SendEmail")
      assert SensitivityMatrix.known_tool?("WebFetch")
    end

    test "returns false for unknown tools" do
      refute SensitivityMatrix.known_tool?("ExternalAPITool")
      refute SensitivityMatrix.known_tool?("")
    end
  end
end
