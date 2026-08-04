defmodule TriOnyx.RiskManifestTest do
  use ExUnit.Case, async: false

  alias TriOnyx.RepoStore
  alias TriOnyx.RiskManifest
  alias TriOnyx.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    ws = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(ws)

    previous = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, ws)

    on_exit(fn ->
      if previous do
        Application.put_env(:tri_onyx, :workspace_dir, previous)
      else
        Application.delete_env(:tri_onyx, :workspace_dir)
      end
    end)

    %{ws: ws}
  end

  # Writes files into an agent's tree and commits them with provenance
  # trailers, exactly like a session-end commit.
  defp commit_write(agent, rel_paths, taint, sensitivity, content \\ "content") do
    repo = {:agent, agent}
    :ok = RepoStore.ensure_tree(agent, repo)
    tree = RepoStore.tree_dir(agent, repo)

    Enum.each(rel_paths, fn rel ->
      abs = Path.join(tree, rel)
      File.mkdir_p!(Path.dirname(abs))
      File.write!(abs, content)
    end)

    {:ok, sha} =
      RepoStore.commit_and_push(agent, repo,
        author: agent,
        message: "#{agent} session test",
        trailers: ["Taint-Level: #{taint}", "Sensitivity-Level: #{sensitivity}"],
        session_id: "test"
      )

    sha
  end

  # Sweep-style commit without trailers.
  defp commit_plain(agent, fun) do
    repo = {:agent, agent}
    tree = RepoStore.tree_dir(agent, repo)
    fun.(tree)

    {:ok, _} =
      RepoStore.commit_and_push(agent, repo,
        author: "sweep",
        message: "[sweep] uncommitted changes",
        session_id: "sweep"
      )
  end

  defp start_manifest! do
    name = :"risk_manifest_#{System.unique_integer([:positive])}"
    start_supervised!({RiskManifest, name: name})
    name
  end

  describe "rebuild from repo histories" do
    test "loads labels from provenance commit trailers under canonical paths" do
      commit_write("news", ["digest.md"], :high, :medium)

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "high"
      assert entry["sensitivity_level"] == "medium"
      assert entry["risk_level"] == "high"
      assert entry["agent"] == "news"
      assert is_binary(entry["updated_at"])
    end

    test "the most recent provenance commit wins" do
      commit_write("news", ["digest.md"], :low, :low, "v1")
      commit_write("news", ["digest.md"], :high, :medium, "v2")

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "high"
    end

    test "deleted files have no entry" do
      commit_write("news", ["incoming/article.md"], :high, :low)

      commit_plain("news", fn tree ->
        File.rm!(Path.join(tree, "incoming/article.md"))
      end)

      name = start_manifest!()

      assert :error = RiskManifest.lookup(name, "agents/news/incoming/article.md")
    end

    test "commits without provenance trailers keep older labels" do
      commit_write("news", ["notes.md"], :medium, :low, "v1")

      commit_plain("news", fn tree ->
        File.write!(Path.join(tree, "notes.md"), "manually edited")
      end)

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/notes.md")
      assert entry["taint_level"] == "medium"
      assert entry["agent"] == "news"
    end

    test "review commits reset taint but keep sensitivity" do
      commit_write("news", ["digest.md"], :high, :medium)

      {:ok, _} =
        RepoStore.empty_commit({:agent, "news"}, "sondre", "review by sondre", [
          "Taint-Level: low",
          "Reviewed-By: sondre",
          "Reviewed-Path: agents/news/digest.md"
        ])

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "low"
      assert entry["sensitivity_level"] == "medium"
      assert entry["risk_level"] == "medium"
      assert entry["reviewed_by"] == "sondre"
    end

    test "a write after a review re-taints the file" do
      commit_write("news", ["digest.md"], :high, :low, "v1")

      {:ok, _} =
        RepoStore.empty_commit({:agent, "news"}, "sondre", "review by sondre", [
          "Reviewed-By: sondre",
          "Reviewed-Path: agents/news/digest.md"
        ])

      commit_write("news", ["digest.md"], :high, :low, "v2")

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "high"
      refute Map.has_key?(entry, "reviewed_by")
    end

    test "entries from several repos coexist" do
      commit_write("news", ["a.md"], :high, :low)
      commit_write("wiki", ["b.md"], :low, :medium)

      name = start_manifest!()

      assert {:ok, _} = RiskManifest.lookup(name, "agents/news/a.md")
      assert {:ok, _} = RiskManifest.lookup(name, "agents/wiki/b.md")
    end

    test "starts empty without any repos" do
      name = start_manifest!()
      assert RiskManifest.snapshot(name) == %{}
    end

    test "migration snapshot seeds paths without live history", %{ws: ws} do
      commit_write("news", ["fresh.md"], :low, :low)

      snapshot = %{
        "agents/news/fresh.md" => %{"taint_level" => "high", "sensitivity_level" => "high"},
        "agents/legacy/old.md" => %{"taint_level" => "medium", "sensitivity_level" => "low"}
      }

      File.mkdir_p!(Path.join(ws, "data"))
      File.write!(Path.join(ws, "data/risk-manifest-snapshot.json"), Jason.encode!(snapshot))

      name = start_manifest!()

      # Live history wins for fresh.md; snapshot fills the legacy path.
      assert {:ok, %{"taint_level" => "low"}} =
               RiskManifest.lookup(name, "agents/news/fresh.md")

      assert {:ok, %{"taint_level" => "medium"}} =
               RiskManifest.lookup(name, "agents/legacy/old.md")
    end
  end

  describe "live updates" do
    test "put and lookup round-trip" do
      name = start_manifest!()

      :ok = RiskManifest.put(name, "news", ["agents/news/a.md", "agents/news/b.md"], :high, :low)

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/a.md")
      assert entry["taint_level"] == "high"
      assert entry["sensitivity_level"] == "low"
      assert entry["risk_level"] == "high"
      assert entry["agent"] == "news"
      assert {:ok, _} = RiskManifest.lookup(name, "agents/news/b.md")
    end

    test "review resets taint and keeps sensitivity" do
      name = start_manifest!()

      :ok = RiskManifest.put(name, "news", ["agents/news/a.md"], :high, :medium)
      :ok = RiskManifest.review(name, ["agents/news/a.md"], "sondre")

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/a.md")
      assert entry["taint_level"] == "low"
      assert entry["sensitivity_level"] == "medium"
      assert entry["risk_level"] == "medium"
      assert entry["reviewed_by"] == "sondre"
    end

    test "reload drops live entries that are not in git history" do
      commit_write("news", ["committed.md"], :medium, :low)

      name = start_manifest!()
      :ok = RiskManifest.put(name, "news", ["agents/news/uncommitted.md"], :high, :low)

      :ok = RiskManifest.reload(name)

      assert {:ok, _} = RiskManifest.lookup(name, "agents/news/committed.md")
      assert :error = RiskManifest.lookup(name, "agents/news/uncommitted.md")
    end

    test "max_labels_for_prefixes aggregates over repo prefixes" do
      name = start_manifest!()

      :ok = RiskManifest.put(name, "news", ["agents/news/a.md"], :high, :low)
      :ok = RiskManifest.put(name, "wiki", ["shared/knowledge/b.md"], :low, :medium)
      :ok = RiskManifest.put(name, "finn", ["agents/finn/c.md"], :medium, :high)

      assert {:high, :medium, _} =
               RiskManifest.max_labels_for_prefixes(name, ["agents/news/", "shared/knowledge/"])

      assert {:low, :low, nil} = RiskManifest.max_labels_for_prefixes(name, ["agents/nobody/"])
    end
  end

  describe "review_artifacts integration" do
    test "reviews persist through a git-history rebuild" do
      commit_write("news", ["digest.md"], :high, :medium)

      # review_artifacts updates the globally named instance and records
      # the review as an empty commit with Reviewed-Path trailers.
      assert {:ok, _} = Workspace.review_artifacts(["agents/news/digest.md"], "sondre")

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "low"
      assert entry["sensitivity_level"] == "medium"
      assert entry["reviewed_by"] == "sondre"
    end

    test "rejects paths containing newlines" do
      assert {:error, :invalid_path} =
               Workspace.review_artifacts(["agents/news/a\nReviewed-Path: b"], "sondre")
    end

    test "rejects non-canonical paths" do
      assert {:error, :invalid_path} = Workspace.review_artifacts(["notes.md"], "sondre")
    end
  end
end
