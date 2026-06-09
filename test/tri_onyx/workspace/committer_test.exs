defmodule TriOnyx.Workspace.CommitterTest do
  use ExUnit.Case, async: false

  alias TriOnyx.RiskManifest
  alias TriOnyx.Workspace.Committer

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

    # The committer writes into the globally named RiskManifest instance.
    RiskManifest.clear()
    on_exit(fn -> RiskManifest.clear() end)

    name = :"committer_#{System.unique_integer([:positive])}"
    start_supervised!({Committer, name: name, debounce_ms: 60_000})

    %{repo: repo, committer: name}
  end

  defp write_file(repo, rel_path, content) do
    abs = Path.join(repo, rel_path)
    File.mkdir_p!(Path.dirname(abs))
    File.write!(abs, content)
  end

  defp last_commit_message(repo) do
    {out, 0} = System.cmd("git", ["log", "--format=%B", "-1"], cd: repo, stderr_to_stdout: true)
    String.trim(out)
  end

  defp commit_count(repo) do
    case System.cmd("git", ["rev-list", "--count", "HEAD"], cd: repo, stderr_to_stdout: true) do
      {out, 0} -> out |> String.trim() |> String.to_integer()
      _ -> 0
    end
  end

  test "record_write updates the risk manifest immediately, before any commit",
       %{repo: repo, committer: committer} do
    write_file(repo, "agents/news/notes.md", "content")

    Committer.record_write(committer, "news", "sess-1", "agents/news/notes.md", :high, :medium)

    # Cast is async — sync on the server before asserting.
    _ = :sys.get_state(committer)

    manifest = RiskManifest.snapshot()
    entry = manifest["agents/news/notes.md"]
    assert entry["taint_level"] == "high"
    assert entry["sensitivity_level"] == "medium"
    assert entry["agent"] == "news"

    # No commit yet — debounce has not fired and flush was not called.
    assert commit_count(repo) == 0
  end

  test "flush commits dirty paths with provenance trailers",
       %{repo: repo, committer: committer} do
    write_file(repo, "agents/news/notes.md", "content")

    Committer.record_write(committer, "news", "sess-1", "agents/news/notes.md", :medium, :low)
    :ok = Committer.flush(committer)

    assert commit_count(repo) == 1
    message = last_commit_message(repo)
    assert message =~ "news session sess-1"
    assert message =~ "Taint-Level: medium"
    assert message =~ "Sensitivity-Level: low"

    # Only the written file is committed — the risk manifest lives in
    # memory and is rebuilt from these commit trailers.
    {out, 0} =
      System.cmd("git", ["show", "--name-only", "--format=", "HEAD"],
        cd: repo,
        stderr_to_stdout: true
      )

    assert out =~ "agents/news/notes.md"
    refute out =~ ".tri-onyx"
  end

  test "atomic-write temp files are ignored", %{repo: repo, committer: committer} do
    write_file(repo, "agents/news/NOTES.md.tmp.50.1771023878427", "tmp")

    Committer.record_write(
      committer,
      "news",
      "sess-1",
      "agents/news/NOTES.md.tmp.50.1771023878427",
      :low,
      :low
    )

    :ok = Committer.flush(committer)

    assert commit_count(repo) == 0
    assert RiskManifest.snapshot() == %{}
  end

  test "created-then-deleted paths do not block other commits",
       %{repo: repo, committer: committer} do
    write_file(repo, "incoming/article.md", "fetched")
    write_file(repo, "agents/news/digest.md", "digest")

    Committer.record_write(committer, "news", "sess-1", "incoming/article.md", :high, :low)
    Committer.record_write(committer, "news", "sess-1", "agents/news/digest.md", :high, :low)

    # The article is reviewed and discarded before the commit fires.
    File.rm!(Path.join(repo, "incoming/article.md"))

    :ok = Committer.flush(committer)

    assert commit_count(repo) == 1

    {out, 0} =
      System.cmd("git", ["show", "--name-only", "--format=", "HEAD"],
        cd: repo,
        stderr_to_stdout: true
      )

    assert out =~ "agents/news/digest.md"
    refute out =~ "incoming/article.md"
  end

  test "labels are point-in-time: paths written at different risk levels get separate commits",
       %{repo: repo, committer: committer} do
    write_file(repo, "agents/news/early.md", "written while clean")
    write_file(repo, "agents/news/late.md", "written after escalation")

    Committer.record_write(committer, "news", "sess-1", "agents/news/early.md", :low, :low)
    Committer.record_write(committer, "news", "sess-1", "agents/news/late.md", :high, :low)

    :ok = Committer.flush(committer)

    manifest = RiskManifest.snapshot()
    assert manifest["agents/news/early.md"]["taint_level"] == "low"
    assert manifest["agents/news/late.md"]["taint_level"] == "high"

    # One commit per (agent, session, labels) group.
    assert commit_count(repo) == 2
  end

  test "debounce timer commits without an explicit flush", %{repo: repo} do
    name = :"committer_fast_#{System.unique_integer([:positive])}"
    start_supervised!({Committer, name: name, debounce_ms: 50}, id: name)

    write_file(repo, "agents/news/notes.md", "content")
    Committer.record_write(name, "news", "sess-1", "agents/news/notes.md", :low, :low)

    Process.sleep(500)

    assert commit_count(repo) == 1
  end
end
