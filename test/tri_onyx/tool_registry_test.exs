defmodule TriOnyx.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias TriOnyx.ToolRegistry

  describe "known?/1" do
    test "returns true for built-in tools" do
      for tool <- ["Read", "Write", "Bash", "Grep", "Glob", "Edit", "WebFetch", "WebSearch",
                    "SendMessage", "BCTPQuery", "BCTPRespond", "RestartAgent",
                    "SendEmail", "MoveEmail", "CreateFolder", "NotebookEdit"] do
        assert ToolRegistry.known?(tool), "expected #{tool} to be known"
      end
    end

    test "returns false for unknown tools" do
      refute ToolRegistry.known?("MagicTool")
      refute ToolRegistry.known?("FlyToMoon")
    end
  end

  describe "validate_tools/1" do
    test "returns :ok for all known tools" do
      assert :ok = ToolRegistry.validate_tools(["Read", "Grep", "Glob"])
    end

    test "returns error for unknown tools" do
      assert {:error, {:unknown_tools, ["MagicTool"]}} =
               ToolRegistry.validate_tools(["Read", "MagicTool"])
    end

    test "returns :ok for empty list" do
      assert :ok = ToolRegistry.validate_tools([])
    end
  end

  describe "requires_auth?/1" do
    test "email tools require auth" do
      assert ToolRegistry.requires_auth?("SendEmail")
      assert ToolRegistry.requires_auth?("MoveEmail")
      assert ToolRegistry.requires_auth?("CreateFolder")
    end

    test "non-auth tools do not require auth" do
      refute ToolRegistry.requires_auth?("Read")
      refute ToolRegistry.requires_auth?("Bash")
      refute ToolRegistry.requires_auth?("WebFetch")
    end
  end

  describe "tool_meta/1" do
    test "returns auth metadata for known tools" do
      meta = ToolRegistry.tool_meta("SendEmail")
      assert meta.requires_auth == true
    end

    test "returns default metadata for unknown tools" do
      meta = ToolRegistry.tool_meta("UnknownTool")
      assert meta.requires_auth == false
    end
  end
end
