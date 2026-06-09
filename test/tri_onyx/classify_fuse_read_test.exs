defmodule TriOnyx.ClassifyFuseReadTest do
  use ExUnit.Case, async: false

  alias TriOnyx.InformationClassifier
  alias TriOnyx.RiskManifest

  setup do
    RiskManifest.clear()
    on_exit(fn -> RiskManifest.clear() end)
    :ok
  end

  test "returns manifest labels for a labeled file" do
    RiskManifest.put("news", ["agents/news/digest.md"], :high, :medium)

    assert {:ok, classification} = InformationClassifier.classify_fuse_read("/agents/news/digest.md")
    assert classification.taint == :high
    assert classification.sensitivity == :medium
    assert classification.reason =~ "agents/news/digest.md"
    assert classification.reason =~ "written by news"
  end

  test "path is matched without the FUSE mount's leading slash" do
    RiskManifest.put("wiki", ["notes.md"], :medium, :low)

    assert {:ok, %{taint: :medium}} = InformationClassifier.classify_fuse_read("/notes.md")
    assert {:ok, %{taint: :medium}} = InformationClassifier.classify_fuse_read("notes.md")
  end

  test "returns :unclassified for files without a manifest entry" do
    RiskManifest.put("news", ["agents/news/known.md"], :low, :low)

    assert :unclassified = InformationClassifier.classify_fuse_read("/agents/news/unknown.md")
  end

  test "returns :unclassified when the manifest is empty" do
    assert :unclassified = InformationClassifier.classify_fuse_read("/anything.md")
  end
end
