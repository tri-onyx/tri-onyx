defmodule TriOnyx.ToolRegistryTest do
  use ExUnit.Case, async: true

  alias TriOnyx.ToolRegistry

  describe "known?/1" do
    test "returns true for built-in tools" do
      for tool <- ["Read", "Write", "Bash", "Grep", "Glob", "Edit", "WebFetch", "WebSearch",
                    "SendMessage", "BCPQuery", "BCPRespond", "RestartAgent",
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

  describe "requires_approval?/1" do
    test "SendEmail requires approval" do
      assert ToolRegistry.requires_approval?("SendEmail")
    end

    test "other tools do not require approval" do
      refute ToolRegistry.requires_approval?("Read")
      refute ToolRegistry.requires_approval?("Bash")
      refute ToolRegistry.requires_approval?("MoveEmail")
      refute ToolRegistry.requires_approval?("CalendarCreate")
    end

    test "unknown tools default to false" do
      refute ToolRegistry.requires_approval?("UnknownTool")
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

  describe "cross-matrix consistency" do
    # The risk model is spread across ToolRegistry (capability/auth),
    # TaintMatrix, SensitivityMatrix, and the display entries. A tool added
    # to one module but forgotten in another would silently fall back to
    # :low in the matrices, understating risk. These tests make that
    # omission a build failure instead.
    test "every known tool has an explicit taint entry" do
      missing = ToolRegistry.known_tools() -- Map.keys(TriOnyx.TaintMatrix.all_tool_taints())
      assert missing == []
    end

    test "every known tool has an explicit sensitivity entry" do
      missing =
        ToolRegistry.known_tools() -- Map.keys(TriOnyx.SensitivityMatrix.all_tool_sensitivities())

      assert missing == []
    end

    test "every known tool has a display entry" do
      displayed = ToolRegistry.display_entries() |> Enum.map(& &1.display) |> Enum.uniq()
      missing = ToolRegistry.known_tools() -- displayed
      assert missing == []
    end
  end
end
