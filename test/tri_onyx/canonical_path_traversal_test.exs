defmodule TriOnyx.CanonicalPathTraversalTest do
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
    test "a workspace-relative traversal into a mounted repo maps to the same canonical path as addressing it directly" do
      # Both container paths are resolved by the OS/container mount
      # namespace to the exact same real file: /repos/knowledge/secret.md
      # (/workspace and /repos are sibling mounts under the container
      # root, so "/workspace/.." lands back at "/").
      assert {:ok, direct} = Workspace.canonical_path("attacker", "/repos/knowledge/secret.md")

      assert {:ok, via_traversal} =
               Workspace.canonical_path("attacker", "/workspace/../repos/knowledge/secret.md")

      assert direct == via_traversal
    end
  end

  describe "Read tool sensitivity classification" do
    test "reading a high-sensitivity mounted file via a workspace-relative traversal is still classified :high" do
      # A real prior session already recorded this shared file as highly
      # sensitive in the risk manifest.
      RiskManifest.put("wiki", ["shared/knowledge/secret.md"], :low, :high)

      direct =
        InformationClassifier.classify_tool_result(
          "Read",
          %{"file_path" => "/repos/knowledge/secret.md"},
          %{agent_name: "attacker"}
        )

      # Same real bytes, addressed via a traversal that stays inside the
      # agent's own mounts (controlled_path?/1 already normalizes and
      # accepts it) — the sensitivity label must not depend on how the
      # already-accessible file was spelled.
      laundered =
        InformationClassifier.classify_tool_result(
          "Read",
          %{"file_path" => "/workspace/../repos/knowledge/secret.md"},
          %{agent_name: "attacker"}
        )

      assert %{sensitivity: :high} = direct
      assert %{sensitivity: :high} = laundered
    end
  end
end
