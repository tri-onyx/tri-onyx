defmodule TriOnyx.RiskManifestTest do
  use ExUnit.Case, async: false

  alias TriOnyx.RiskManifest
  alias TriOnyx.Workspace

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp_dir} do
    repo = Path.join(tmp_dir, "workspace")
    File.mkdir_p!(repo)

    {_, 0} = System.cmd("git", ["init"], cd: repo, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.email", "test@test"], cd: repo, stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["config", "user.name", "Test"], cd: repo, stderr_to_stdout: true)

    previous = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, repo)

    on_exit(fn ->
      if previous do
        Application.put_env(:tri_onyx, :workspace_dir, previous)
      else
        Application.delete_env(:tri_onyx, :workspace_dir)
      end
    end)

    %{repo: repo}
  end

  defp write_file(repo, rel_path, content) do
    abs = Path.join(repo, rel_path)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
  end

  defp git!(repo, args) do
    {out, 0} = System.cmd("git", args, cd: repo, stderr_to_stdout: true)
    out
  end

  defp commit_write(repo, agent, paths, taint, sensitivity, content \\ "content") do
    Enum.each(paths, &write_file(repo, &1, content))
    git!(repo, ["add", "-A"])

    msg =
      "#{agent} session test\n\nTaint-Level: #{taint}\nSensitivity-Level: #{sensitivity}"

    git!(repo, ["commit", "--author=#{agent} <#{agent}@tri_onyx>", "-m", msg])
  end

  defp commit_delete(repo, paths) do
    Enum.each(paths, &File.rm!(Path.join(repo, &1)))
    git!(repo, ["add", "-A"])
    git!(repo, ["commit", "-m", "[sweep] uncommitted workspace changes"])
  end

  defp start_manifest! do
    name = :"risk_manifest_#{System.unique_integer([:positive])}"
    start_supervised!({RiskManifest, name: name})
    name
  end

  describe "rebuild from git history" do
    test "loads labels from provenance commit trailers", %{repo: repo} do
      commit_write(repo, "news", ["agents/news/digest.md"], :high, :medium)

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "high"
      assert entry["sensitivity_level"] == "medium"
      assert entry["risk_level"] == "high"
      assert entry["agent"] == "news"
      assert is_binary(entry["updated_at"])
    end

    test "the most recent provenance commit wins", %{repo: repo} do
      commit_write(repo, "news", ["agents/news/digest.md"], :low, :low, "v1")
      commit_write(repo, "wiki", ["agents/news/digest.md"], :high, :medium, "v2")

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "high"
      assert entry["agent"] == "wiki"
    end

    test "deleted files have no entry", %{repo: repo} do
      commit_write(repo, "news", ["incoming/article.md"], :high, :low)
      commit_delete(repo, ["incoming/article.md"])

      name = start_manifest!()

      assert :error = RiskManifest.lookup(name, "incoming/article.md")
    end

    test "commits without provenance trailers keep older labels", %{repo: repo} do
      commit_write(repo, "news", ["agents/news/notes.md"], :medium, :low, "v1")

      # Sweep-style commit (no trailers) touches the same file.
      write_file(repo, "agents/news/notes.md", "manually edited")
      git!(repo, ["add", "-A"])
      git!(repo, ["commit", "-m", "[sweep] uncommitted workspace changes"])

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/notes.md")
      assert entry["taint_level"] == "medium"
      assert entry["agent"] == "news"
    end

    test "review commits reset taint but keep sensitivity", %{repo: repo} do
      commit_write(repo, "news", ["agents/news/digest.md"], :high, :medium)

      msg =
        "review by sondre\n\n" <>
          "Taint-Level: low\nReviewed-By: sondre\nReviewed-Path: agents/news/digest.md"

      git!(repo, ["commit", "--allow-empty", "--author=sondre <sondre@tri_onyx>", "-m", msg])

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "low"
      assert entry["sensitivity_level"] == "medium"
      assert entry["risk_level"] == "medium"
      assert entry["reviewed_by"] == "sondre"
    end

    test "a write after a review re-taints the file", %{repo: repo} do
      commit_write(repo, "news", ["agents/news/digest.md"], :high, :low, "v1")

      msg = "review by sondre\n\nReviewed-By: sondre\nReviewed-Path: agents/news/digest.md"
      git!(repo, ["commit", "--allow-empty", "-m", msg])

      commit_write(repo, "news", ["agents/news/digest.md"], :high, :low, "v2")

      name = start_manifest!()

      assert {:ok, entry} = RiskManifest.lookup(name, "agents/news/digest.md")
      assert entry["taint_level"] == "high"
      refute Map.has_key?(entry, "reviewed_by")
    end

    test "legacy .tri-onyx manifest file commits are ignored", %{repo: repo} do
      commit_write(repo, "news", [".tri-onyx/risk-manifest.json"], :high, :high, "{}")

      name = start_manifest!()

      assert RiskManifest.snapshot(name) == %{}
    end

    test "starts empty without a workspace git repository" do
      Application.put_env(:tri_onyx, :workspace_dir, "test/tmp/does-not-exist")

      name = start_manifest!()

      assert RiskManifest.snapshot(name) == %{}
    end
  end

  describe "live updates" do
    test "put and lookup round-trip" do
      name = start_manifest!()

      :ok = RiskManifest.put(name, "news", ["a.md", "b.md"], :high, :low)

      assert {:ok, entry} = RiskManifest.lookup(name, "a.md")
      assert entry["taint_level"] == "high"
      assert entry["sensitivity_level"] == "low"
      assert entry["risk_level"] == "high"
      assert entry["agent"] == "news"
      assert {:ok, _} = RiskManifest.lookup(name, "b.md")
    end

    test "review resets taint and keeps sensitivity" do
      name = start_manifest!()

      :ok = RiskManifest.put(name, "news", ["a.md"], :high, :medium)
      :ok = RiskManifest.review(name, ["a.md"], "sondre")

      assert {:ok, entry} = RiskManifest.lookup(name, "a.md")
      assert entry["taint_level"] == "low"
      assert entry["sensitivity_level"] == "medium"
      assert entry["risk_level"] == "medium"
      assert entry["reviewed_by"] == "sondre"
    end

    test "reload drops live entries that are not in git history", %{repo: repo} do
      commit_write(repo, "news", ["committed.md"], :medium, :low)

      name = start_manifest!()
      :ok = RiskManifest.put(name, "news", ["uncommitted.md"], :high, :low)

      :ok = RiskManifest.reload(name)

      assert {:ok, _} = RiskManifest.lookup(name, "committed.md")
      assert :error = RiskManifest.lookup(name, "uncommitted.md")
    end
  end

  describe "review_artifacts integration" do
    test "reviews persist through a git-history rebuild", %{repo: repo} do
      commit_write(repo, "news", ["agents/news/digest.md"], :high, :medium)

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
      assert {:error, :invalid_path} = Workspace.review_artifacts(["a\nReviewed-Path: b"], "sondre")
    end
  end
end
