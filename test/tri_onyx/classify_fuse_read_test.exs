defmodule TriOnyx.ClassifyFuseReadTest do
  use ExUnit.Case, async: false

  alias TriOnyx.InformationClassifier

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    workspace = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(Path.join(workspace, ".tri-onyx"))

    previous = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, workspace)

    on_exit(fn ->
      if previous do
        Application.put_env(:tri_onyx, :workspace_dir, previous)
      else
        Application.delete_env(:tri_onyx, :workspace_dir)
      end
    end)

    %{workspace: workspace}
  end

  defp write_manifest(workspace, entries) do
    manifest = Path.join([workspace, ".tri-onyx", "risk-manifest.json"])
    File.write!(manifest, Jason.encode!(entries))
  end

  test "returns manifest labels for a labeled file", %{workspace: workspace} do
    write_manifest(workspace, %{
      "agents/news/digest.md" => %{
        "taint_level" => "high",
        "sensitivity_level" => "medium",
        "agent" => "news"
      }
    })

    assert {:ok, classification} = InformationClassifier.classify_fuse_read("/agents/news/digest.md")
    assert classification.taint == :high
    assert classification.sensitivity == :medium
    assert classification.reason =~ "agents/news/digest.md"
    assert classification.reason =~ "written by news"
  end

  test "path is matched without the FUSE mount's leading slash", %{workspace: workspace} do
    write_manifest(workspace, %{
      "notes.md" => %{"taint_level" => "medium", "sensitivity_level" => "low", "agent" => "wiki"}
    })

    assert {:ok, %{taint: :medium}} = InformationClassifier.classify_fuse_read("/notes.md")
    assert {:ok, %{taint: :medium}} = InformationClassifier.classify_fuse_read("notes.md")
  end

  test "returns :unclassified for files without a manifest entry", %{workspace: workspace} do
    write_manifest(workspace, %{})

    assert :unclassified = InformationClassifier.classify_fuse_read("/agents/news/unknown.md")
  end

  test "returns :unclassified when no manifest exists" do
    assert :unclassified = InformationClassifier.classify_fuse_read("/anything.md")
  end

  test "malformed levels default to :low", %{workspace: workspace} do
    write_manifest(workspace, %{
      "weird.md" => %{"taint_level" => "banana", "agent" => "news"}
    })

    assert {:ok, %{taint: :low, sensitivity: :low}} =
             InformationClassifier.classify_fuse_read("/weird.md")
  end
end
