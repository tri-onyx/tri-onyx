defmodule TriOnyx.RepoStoreTest do
  use ExUnit.Case, async: false

  alias TriOnyx.RepoStore

  setup do
    tmp = Path.join(["test", "tmp", "repo_store_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(tmp)
    original = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, tmp)

    on_exit(fn ->
      Application.put_env(:tri_onyx, :workspace_dir, original)
      File.rm_rf!(tmp)
    end)

    {:ok, tmp: tmp}
  end

  test "ensure_repo creates a bare repo with a root commit on main" do
    repo = {:agent, "news"}
    assert :ok = RepoStore.ensure_repo(repo)
    assert RepoStore.exists?(repo)

    bare = RepoStore.bare_dir(repo)
    {out, 0} = System.cmd("git", ["--git-dir", bare, "log", "--oneline"], stderr_to_stdout: true)
    assert out =~ "initialize repo"

    {branch, 0} =
      System.cmd("git", ["--git-dir", bare, "symbolic-ref", "--short", "HEAD"],
        stderr_to_stdout: true
      )

    assert String.trim(branch) == "main"

    # Idempotent
    assert :ok = RepoStore.ensure_repo(repo)
  end

  test "ensure_tree creates a working tree with no .git entry" do
    repo = {:agent, "news"}
    assert :ok = RepoStore.ensure_tree("news", repo)

    tree = RepoStore.tree_dir("news", repo)
    assert File.dir?(tree)
    refute File.exists?(Path.join(tree, ".git"))
    assert String.ends_with?(tree, "trees/news/self")
  end

  test "commit_and_push lands changes in the bare repo and _ro checkout" do
    repo = {:agent, "news"}
    :ok = RepoStore.ensure_tree("news", repo)
    tree = RepoStore.tree_dir("news", repo)

    File.write!(Path.join(tree, "NOTES.md"), "hello\n")

    assert {:ok, sha} =
             RepoStore.commit_and_push("news", repo,
               message: "news session abc123",
               trailers: ["Taint-Level: low"],
               session_id: "abc123"
             )

    assert is_binary(sha)

    # Commit is in the bare repo with author + trailer
    {log, 0} =
      System.cmd(
        "git",
        ["--git-dir", RepoStore.bare_dir(repo), "log", "-1", "--format=%an|%B"],
        stderr_to_stdout: true
      )

    assert log =~ "news|news session abc123"
    assert log =~ "Taint-Level: low"

    # _ro checkout reflects it after refresh
    assert :ok = RepoStore.refresh_ro(repo)
    ro_tree = RepoStore.tree_dir(:ro, repo)
    assert File.read!(Path.join(ro_tree, "NOTES.md")) == "hello\n"
  end

  test "commit_and_push with no changes reports no_changes" do
    repo = {:shared, "core"}
    :ok = RepoStore.ensure_tree(:gw, repo)

    assert {:ok, :no_changes} =
             RepoStore.commit_and_push(:gw, repo, message: "noop", session_id: "s1")
  end

  test "a second principal picks up pushed changes via sync_tree" do
    repo = {:shared, "knowledge"}
    :ok = RepoStore.ensure_tree("news", repo)
    :ok = RepoStore.ensure_tree("wiki", repo)

    news_tree = RepoStore.tree_dir("news", repo)
    File.mkdir_p!(Path.join(news_tree, "sources"))
    File.write!(Path.join(news_tree, "sources/article.md"), "content\n")

    {:ok, _sha} =
      RepoStore.commit_and_push("news", repo, message: "news session s1", session_id: "s1")

    wiki_tree = RepoStore.tree_dir("wiki", repo)
    refute File.exists?(Path.join(wiki_tree, "sources/article.md"))

    assert :ok = RepoStore.sync_tree("wiki", repo)
    assert File.read!(Path.join(wiki_tree, "sources/article.md")) == "content\n"
  end

  test "sync_tree hands tree ownership to the configured agent uid" do
    repo = {:shared, "knowledge"}
    :ok = RepoStore.ensure_tree(:gw, repo)
    gw_tree = RepoStore.tree_dir(:gw, repo)
    File.write!(Path.join(gw_tree, "note.md"), "hello\n")
    {:ok, _} = RepoStore.commit_and_push(:gw, repo, message: "seed", session_id: "s1")

    {my_uid, 0} = System.cmd("id", ["-u"], stderr_to_stdout: true)
    my_uid = String.trim(my_uid)

    # Running as root (the gateway container), a real handover to a
    # different uid is observable. As an unprivileged user, chown to the
    # current owner still exercises the code path as a no-op.
    {uid, gid} = if my_uid == "0", do: {"1234", "1234"}, else: {my_uid, my_uid}

    Application.put_env(:tri_onyx, :tree_owner_uid, uid)
    Application.put_env(:tri_onyx, :tree_owner_gid, gid)

    on_exit(fn ->
      Application.delete_env(:tri_onyx, :tree_owner_uid)
      Application.delete_env(:tri_onyx, :tree_owner_gid)
    end)

    assert :ok = RepoStore.sync_tree("news", repo)

    tree = RepoStore.tree_dir("news", repo)
    expected = String.to_integer(uid)
    assert File.stat!(tree).uid == expected
    assert File.stat!(Path.join(tree, "note.md")).uid == expected

    # The gateway's own tree is never handed over
    assert :ok = RepoStore.sync_tree(:gw, repo)
    assert File.stat!(gw_tree).uid != expected or my_uid == uid
  end

  test "non-conflicting concurrent edits merge; conflicting edits get parked" do
    repo = {:shared, "knowledge"}
    :ok = RepoStore.ensure_tree("a", repo)
    :ok = RepoStore.ensure_tree("b", repo)

    a_tree = RepoStore.tree_dir("a", repo)
    b_tree = RepoStore.tree_dir("b", repo)

    # Disjoint files: both should land on main via merge
    File.write!(Path.join(a_tree, "a.md"), "from a\n")
    File.write!(Path.join(b_tree, "b.md"), "from b\n")

    {:ok, _} = RepoStore.commit_and_push("a", repo, message: "a s1", session_id: "s1")
    {:ok, _} = RepoStore.commit_and_push("b", repo, message: "b s1", session_id: "s1")

    :ok = RepoStore.sync_tree("a", repo)
    assert File.exists?(Path.join(a_tree, "b.md"))

    # Same file, divergent content: second push parks on a conflict branch
    File.write!(Path.join(a_tree, "shared.md"), "version a\n")
    File.write!(Path.join(b_tree, "shared.md"), "version b\n")

    {:ok, _} = RepoStore.commit_and_push("a", repo, message: "a s2", session_id: "s2")

    assert {:ok, {:conflict, branch}} =
             RepoStore.commit_and_push("b", repo, message: "b s2", session_id: "s2")

    assert branch == "conflict/b/s2"

    # The conflict branch exists in the bare repo and b's tree is clean on main
    {refs, 0} =
      System.cmd("git", ["--git-dir", RepoStore.bare_dir(repo), "branch", "--list"],
        stderr_to_stdout: true
      )

    assert refs =~ "conflict/b/s2"
    assert File.read!(Path.join(b_tree, "shared.md")) == "version a\n"
    refute RepoStore.dirty?("b", repo)
  end

  test "changed_paths lists dirty paths relative to the tree" do
    repo = {:agent, "main"}
    :ok = RepoStore.ensure_tree("main", repo)
    tree = RepoStore.tree_dir("main", repo)
    File.mkdir_p!(Path.join(tree, "memory"))
    File.write!(Path.join(tree, "memory/2026-08-04.md"), "x\n")

    assert "memory/2026-08-04.md" in RepoStore.changed_paths("main", repo)
    assert RepoStore.dirty?("main", repo)
  end

  test "expand_refs resolves the agents/* wildcard from disk" do
    :ok = RepoStore.ensure_repo({:agent, "news"})
    :ok = RepoStore.ensure_repo({:agent, "wiki"})
    :ok = RepoStore.ensure_repo({:shared, "core"})

    assert RepoStore.expand_refs(["agents/*", "core"]) |> Enum.sort() ==
             [{:agent, "news"}, {:agent, "wiki"}, {:shared, "core"}]

    assert RepoStore.expand_refs(["agents/news"]) == [{:agent, "news"}]
  end

  test "read_file_at_commit returns historical content" do
    repo = {:agent, "news"}
    :ok = RepoStore.ensure_tree("news", repo)
    tree = RepoStore.tree_dir("news", repo)

    File.write!(Path.join(tree, "f.md"), "v1\n")
    {:ok, sha1} = RepoStore.commit_and_push("news", repo, message: "s1", session_id: "s1")

    File.write!(Path.join(tree, "f.md"), "v2\n")
    {:ok, _sha2} = RepoStore.commit_and_push("news", repo, message: "s2", session_id: "s2")

    assert {:ok, "v1\n"} = RepoStore.read_file_at_commit(repo, sha1, "f.md")
    assert {:error, :invalid_commit} = RepoStore.read_file_at_commit(repo, "not-a-sha", "f.md")
  end
end
