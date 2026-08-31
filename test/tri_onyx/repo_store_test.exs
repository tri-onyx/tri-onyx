defmodule TriOnyx.RepoStoreTest do
  use ExUnit.Case, async: false

  alias TriOnyx.AgentDefinition
  alias TriOnyx.RepoStore
  alias TriOnyx.RepoStore.Sweeper
  alias TriOnyx.RiskManifest
  alias TriOnyx.Workspace

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

  test "commit_and_push rejects a message that embeds a forged trailer block" do
    repo = {:agent, "news"}
    :ok = RepoStore.ensure_tree("news", repo)
    tree = RepoStore.tree_dir("news", repo)
    File.write!(Path.join(tree, "NOTES.md"), "hello\n")

    # `git log --format=...%(trailers:key=Taint-Level,...)` (RiskManifest's
    # replay format) parses trailers out of the trailing paragraph of the
    # whole commit message, not just what commit_and_push was told to pass
    # as :trailers. A message built from attacker-influenced data (e.g. a
    # SubmitPage file name interpolated by Workspace.commit_page/2) can
    # smuggle in a blank line followed by "Key: value" lines that git then
    # parses as real trailers — forging provenance the gateway never
    # attached.
    forged_message =
      "news page: legit\n\nTaint-Level: low\nSensitivity-Level: low"

    assert {:error, :invalid_commit_message} =
             RepoStore.commit_and_push("news", repo,
               message: forged_message,
               session_id: "s1"
             ),
           "a commit message with an embedded blank line + trailer-shaped lines " <>
             "must be rejected before it reaches git, or it forges provenance"
  end

  test "commit_and_push rejects a trailer value containing a newline" do
    repo = {:agent, "news"}
    :ok = RepoStore.ensure_tree("news", repo)
    tree = RepoStore.tree_dir("news", repo)
    File.write!(Path.join(tree, "NOTES.md"), "hello\n")

    assert {:error, :invalid_commit_message} =
             RepoStore.commit_and_push("news", repo,
               message: "news session s1",
               trailers: ["Taint-Level: low\nSensitivity-Level: low"],
               session_id: "s1"
             )
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

  # --- Helpers ---

  defp definition(name, repos_write, repos_read \\ []) do
    %AgentDefinition{
      name: name,
      tools: ["Read"],
      system_prompt: "test",
      repos_write: repos_write,
      repos_read: repos_read
    }
  end

  # Stands in for the agent port that owns a container: it claims the
  # session's mounts and holds them until it is stopped.
  defp live_container!(principal, ro_repos \\ []) do
    test = self()

    pid =
      spawn(fn ->
        :ok = Sweeper.claim(self(), principal, ro_repos)
        send(test, :claimed)

        receive do
          :stop -> :ok
        end
      end)

    assert_receive :claimed, 5_000
    on_exit(fn -> stop_container(pid) end)
    pid
  end

  defp stop_container(pid) do
    if Process.alive?(pid) do
      ref = Process.monitor(pid)
      send(pid, :stop)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        1_000 -> :ok
      end
    end

    # The claim is released asynchronously, when the custodian sees the exit.
    wait_until(fn -> not Enum.any?(Sweeper.claims(), &(&1.pid == pid)) end)
  end

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never became true")

      true ->
        Process.sleep(10)
        wait_until(fun, attempts - 1)
    end
  end

  # Commits in a tree without pushing, so the tree diverges from its bare repo.
  defp local_commit!(principal, repo_id, message) do
    gd = RepoStore.gitdir(principal, repo_id)
    tree = RepoStore.tree_dir(principal, repo_id)

    env = [
      {"GIT_AUTHOR_NAME", "test"},
      {"GIT_AUTHOR_EMAIL", "test@tri_onyx"},
      {"GIT_COMMITTER_NAME", "test"},
      {"GIT_COMMITTER_EMAIL", "test@tri_onyx"}
    ]

    git = fn args ->
      System.cmd("git", ["-c", "safe.directory=*", "--git-dir", gd, "--work-tree", tree | args],
        stderr_to_stdout: true,
        env: env
      )
    end

    {_, 0} = git.(["add", "-A"])
    {_, 0} = git.(["commit", "-m", message])
    :ok
  end

  defp bare_log(repo_id, format) do
    {out, 0} =
      System.cmd(
        "git",
        ["--git-dir", RepoStore.bare_dir(repo_id), "log", "-1", "--format=#{format}"],
        stderr_to_stdout: true
      )

    out
  end

  # --- Failed-merge recovery ---

  describe "sync_tree merge recovery" do
    setup do
      repo = {:shared, "knowledge"}
      :ok = RepoStore.ensure_tree("a", repo)
      :ok = RepoStore.ensure_tree(:gw, repo)

      # Origin gains a version of shared.md that both trees will conflict with.
      :ok = RepoStore.ensure_tree("origin_writer", repo)
      writer_tree = RepoStore.tree_dir("origin_writer", repo)
      File.write!(Path.join(writer_tree, "shared.md"), "from origin\n")

      {:ok, _} =
        RepoStore.commit_and_push("origin_writer", repo, message: "origin", session_id: "s0")

      %{repo: repo}
    end

    test "an agent tree keeps its work and is left without MERGE_HEAD", %{repo: repo} do
      tree = RepoStore.tree_dir("a", repo)
      File.write!(Path.join(tree, "shared.md"), "from a\n")
      :ok = local_commit!("a", repo, "local work")

      assert {:error, {:sync_failed, _, _}} = RepoStore.sync_tree("a", repo)

      refute File.exists?(Path.join(RepoStore.gitdir("a", repo), "MERGE_HEAD"))
      content = File.read!(Path.join(tree, "shared.md"))
      assert content == "from a\n"
      refute content =~ "<<<<<<<"
    end

    test "a gateway tree is reset onto origin", %{repo: repo} do
      tree = RepoStore.tree_dir(:gw, repo)
      File.write!(Path.join(tree, "shared.md"), "from gw\n")
      :ok = local_commit!(:gw, repo, "local work")

      assert :ok = RepoStore.sync_tree(:gw, repo)

      refute File.exists?(Path.join(RepoStore.gitdir(:gw, repo), "MERGE_HEAD"))
      assert File.read!(Path.join(tree, "shared.md")) == "from origin\n"
    end
  end

  # --- Mount stability ---

  describe "mount claims" do
    test "prepare_session claims the trees it prepared for its caller" do
      test = self()
      definition = definition("mounter", ["knowledge"], ["core"])

      pid =
        spawn(fn ->
          send(test, RepoStore.prepare_session(definition))

          receive do
            :stop -> :ok
          end
        end)

      assert_receive {:ok, %{read: [{:shared, "core"}]}}, 15_000

      assert MapSet.member?(RepoStore.active_principals(), "mounter")
      assert RepoStore.ro_mounted?({:shared, "core"})
      refute RepoStore.ro_mounted?({:shared, "knowledge"})

      stop_container(pid)
      refute MapSet.member?(RepoStore.active_principals(), "mounter")
      refute RepoStore.ro_mounted?({:shared, "core"})
    end

    test "_ro refresh is deferred while a container mounts the checkout" do
      repo = {:shared, "knowledge"}
      :ok = RepoStore.ensure_tree(:gw, repo)
      gw_tree = RepoStore.tree_dir(:gw, repo)
      ro_path = Path.join(RepoStore.tree_dir(:ro, repo), "note.md")

      File.write!(Path.join(gw_tree, "note.md"), "v1\n")
      {:ok, _} = RepoStore.commit_and_push(:gw, repo, message: "v1", session_id: "s1")
      assert File.read!(ro_path) == "v1\n"

      reader = live_container!("reader", [{:shared, "knowledge"}])
      assert RepoStore.ro_mounted?(repo)

      File.write!(Path.join(gw_tree, "note.md"), "v2\n")
      {:ok, _} = RepoStore.commit_and_push(:gw, repo, message: "v2", session_id: "s2")

      # The push landed in the bare repo but the mounted checkout did not move.
      {:ok, sha} = RepoStore.head(repo)
      assert {:ok, "v2\n"} = RepoStore.read_file_at_commit(repo, sha, "note.md")
      assert File.read!(ro_path) == "v1\n"
      assert :ok = RepoStore.refresh_ro(repo)
      assert File.read!(ro_path) == "v1\n"

      # ...and lands once the container is gone (as prepare_session/1 would).
      stop_container(reader)
      refute RepoStore.ro_mounted?(repo)
      assert :ok = RepoStore.refresh_ro(repo)
      assert File.read!(ro_path) == "v2\n"
    end
  end

  # --- Sweeper ---

  describe "Sweeper" do
    test "commits orphaned trees at the unlabeled floor and records them" do
      RiskManifest.clear()
      repo = {:agent, "ghost"}
      :ok = RepoStore.ensure_tree("ghost", repo)
      File.write!(Path.join(RepoStore.tree_dir("ghost", repo), "NOTES.md"), "crashed\n")

      assert {"ghost", "agents/ghost"} in Sweeper.sweep_now()

      body = bare_log(repo, "%B")
      assert body =~ "orphaned uncommitted changes"
      assert body =~ "Taint-Level: high"
      assert body =~ "Sensitivity-Level: high"

      assert {:ok, %{"taint_level" => "high", "sensitivity_level" => "high"}} =
               RiskManifest.lookup("agents/ghost/NOTES.md")
    end

    test "skips trees belonging to a live session" do
      repo = {:agent, "busy"}
      :ok = RepoStore.ensure_tree("busy", repo)
      File.write!(Path.join(RepoStore.tree_dir("busy", repo), "NOTES.md"), "in flight\n")
      live_container!("busy")

      swept = Sweeper.sweep_now()

      refute Enum.any?(swept, fn {principal, _repo} -> principal == "busy" end)
      assert RepoStore.dirty?("busy", repo)
    end
  end

  # --- Label ordering (Workspace façade) ---

  describe "risk labels follow the push" do
    test "a parked session commit leaves its paths unlabeled" do
      RiskManifest.clear()
      shared = {:shared, "knowledge"}
      definition = definition("writer", ["knowledge"])

      :ok = RepoStore.ensure_tree("writer", {:agent, "writer"})
      :ok = RepoStore.ensure_tree("writer", shared)
      :ok = RepoStore.ensure_tree("peer", shared)

      # A peer pushes doc.md first, so the writer's commit cannot merge.
      File.write!(Path.join(RepoStore.tree_dir("peer", shared), "doc.md"), "peer\n")
      {:ok, _} = RepoStore.commit_and_push("peer", shared, message: "peer", session_id: "p1")

      File.write!(Path.join(RepoStore.tree_dir("writer", {:agent, "writer"}), "NOTES.md"), "mine\n")
      File.write!(Path.join(RepoStore.tree_dir("writer", shared), "doc.md"), "writer\n")

      {:ok, results} = Workspace.commit_session(definition, "s1", :high, :medium)

      assert {"knowledge", {:ok, {:conflict, _branch}}} =
               Enum.find(results, fn {repo_ref, _} -> repo_ref == "knowledge" end)

      # Own repo pushed cleanly → labeled; parked shared path → not labeled.
      assert {:ok, %{"taint_level" => "high", "sensitivity_level" => "medium"}} =
               RiskManifest.lookup("agents/writer/NOTES.md")

      assert :error = RiskManifest.lookup("shared/knowledge/doc.md")
    end

    test "a failed review leaves the recorded taint intact", %{tmp: tmp} do
      RiskManifest.clear()
      :ok = RiskManifest.put("news", ["shared/broken/x.md"], :high, :low)

      # A bare path that cannot become a repo makes the review commit fail.
      File.mkdir_p!(Path.join([tmp, "bare", "shared"]))
      File.write!(Path.join([tmp, "bare", "shared", "broken.git"]), "not a repo\n")

      assert {:error, _reason} = Workspace.review_artifacts(["shared/broken/x.md"], "sondre")

      assert {:ok, %{"taint_level" => "high"}} = RiskManifest.lookup("shared/broken/x.md")
    end
  end
end
