defmodule TriOnyx.WorkspaceCanonicalPathTest do
  use ExUnit.Case, async: false

  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskManifest
  alias TriOnyx.Workspace

  setup do
    RiskManifest.clear()
    on_exit(fn -> RiskManifest.clear() end)
    :ok
  end

  describe "canonical_path/2" do
    test "maps plain container paths" do
      assert {:ok, "agents/a/notes.md"} = Workspace.canonical_path("a", "/workspace/notes.md")
      assert {:ok, "agents/a/notes.md"} = Workspace.canonical_path("a", "notes.md")
      assert {:ok, "shared/core/x.md"} = Workspace.canonical_path("a", "/repos/core/x.md")
      assert {:ok, "agents/b/x.md"} = Workspace.canonical_path("a", "/repos/agents/b/x.md")
    end

    test "normalizes dot-dot segments the way the container filesystem does" do
      assert {:ok, "shared/secret/f.md"} =
               Workspace.canonical_path("a", "/workspace/../repos/secret/f.md"),
             "canonical paths must be the real location, or manifest labels are bypassed"

      assert {:ok, "shared/secret/f.md"} =
               Workspace.canonical_path("a", "/repos/other/../secret/f.md")

      assert {:ok, "agents/a/f.md"} = Workspace.canonical_path("a", "sub/../f.md")
      assert :error = Workspace.canonical_path("a", "../etc/passwd")
    end
  end

  test "Read of a high-sensitivity shared file via .. keeps its sensitivity label" do
    RiskManifest.put("a", ["shared/secret/f.md"], :low, :high)

    for path <- [
          "/repos/secret/f.md",
          "/workspace/../repos/secret/f.md",
          "/repos/other/../secret/f.md"
        ] do
      assert %{sensitivity: :high} =
               InformationClassifier.classify_tool_result(
                 "Read",
                 %{"file_path" => path},
                 %{agent_name: "a"}
               ),
             "Read of #{path} must be labelled high-sensitivity (sensitivity gate bypass)"
    end
  end
end
