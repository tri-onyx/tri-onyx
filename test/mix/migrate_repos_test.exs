defmodule Mix.Tasks.TriOnyx.MigrateReposTest do
  use ExUnit.Case, async: false

  alias TriOnyx.RepoStore

  setup do
    tmp = Path.join(["test", "tmp", "migrate_#{System.unique_integer([:positive])}"])
    File.mkdir_p!(tmp)
    original = Application.get_env(:tri_onyx, :workspace_dir)
    Application.put_env(:tri_onyx, :workspace_dir, tmp)
    Mix.shell(Mix.Shell.Process)

    on_exit(fn ->
      Mix.shell(Mix.Shell.IO)
      Application.put_env(:tri_onyx, :workspace_dir, original)
      File.rm_rf!(tmp)
    end)

    build_legacy_workspace(tmp)
    {:ok, ws: tmp}
  end

  defp build_legacy_workspace(ws) do
    write = fn rel, content ->
      path = Path.join(ws, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, content)
    end

    write.("AGENTS.md", "# Agents roster\n")
    write.("personality/SOUL.md", "# Soul content\n")
    write.("agents/news/NOTES.md", "news notes\n")
    write.("agents/news/memory/2026-08-01.md", "memory\n")
    write.("agents/orphan/HEARTBEAT.md", "orphaned state\n")
    write.("plugins/newsagg/pyproject.toml", "[project]\nname='newsagg'\n")
    write.("plugins/newsagg/saved/article.md", "saved article https://example.com/a\n")
    write.("plugins/kb/nodes/n1.md", "kb node\n")
    write.("plugins/unclaimed/README.md", "no owner\n")
    write.("obsidian/shared/index.md", "vault index\n")
    write.("browser-sessions/news/profile.db", "binary\n")

    write.("agent-definitions/news.md", """
    ---
    name: news
    tools: Read
    plugins:
      - newsagg
      - kb
    ---

    News agent prompt.
    """)

    write.("agent-definitions/wiki.md", """
    ---
    name: wiki
    tools: Read
    plugins:
      - kb
    ---

    Wiki agent prompt.
    """)

    # Legacy git repo with a provenance commit so the snapshot export has
    # something to find.
    env = [
      {"GIT_COMMITTER_NAME", "t"},
      {"GIT_COMMITTER_EMAIL", "t@t"},
      {"GIT_AUTHOR_NAME", "news"},
      {"GIT_AUTHOR_EMAIL", "news@tri_onyx"}
    ]

    {_, 0} = System.cmd("git", ["init", "-b", "main", ws], stderr_to_stdout: true)
    {_, 0} = System.cmd("git", ["-C", ws, "add", "-A"], stderr_to_stdout: true, env: env)

    {_, 0} =
      System.cmd(
        "git",
        ["-C", ws, "commit", "-m", "news session s1\n\nTaint-Level: high\nSensitivity-Level: medium"],
        stderr_to_stdout: true,
        env: env
      )
  end

  test "migrates legacy workspace into per-agent repos without losing data", %{ws: ws} do
    Mix.Task.rerun("tri_onyx.migrate_repos", [])

    # Agent repos exist with imported content
    assert RepoStore.exists?({:agent, "news"})
    news_tree = RepoStore.tree_dir("news", {:agent, "news"})
    assert File.read!(Path.join(news_tree, "NOTES.md")) == "news notes\n"
    assert File.read!(Path.join(news_tree, "memory/2026-08-01.md")) == "memory\n"

    # Solely-owned plugin moved into the agent repo
    assert File.exists?(Path.join(news_tree, "plugins/newsagg/saved/article.md"))

    # Multi-owner plugin went to the knowledge shared repo
    kb = Path.join(RepoStore.tree_dir(:gw, {:shared, "knowledge"}), "plugins/kb/nodes/n1.md")
    assert File.read!(kb) == "kb node\n"

    # Obsidian vault in knowledge, personality + AGENTS.md in core,
    # definitions in definitions
    assert File.exists?(
             Path.join(RepoStore.tree_dir(:gw, {:shared, "knowledge"}), "obsidian/shared/index.md")
           )

    core_tree = RepoStore.tree_dir(:gw, {:shared, "core"})
    assert File.read!(Path.join(core_tree, "AGENTS.md")) == "# Agents roster\n"
    assert File.exists?(Path.join(core_tree, "personality/SOUL.md"))

    defs_tree = RepoStore.tree_dir(:gw, {:shared, "definitions"})
    assert File.exists?(Path.join(defs_tree, "news.md"))
    assert File.exists?(Path.join(defs_tree, "wiki.md"))

    # Import commits landed in the bare repos
    {:ok, files} = RepoStore.ls_tree({:agent, "news"})
    assert "NOTES.md" in files
    assert "plugins/newsagg/saved/article.md" in files

    # Non-repo data relocated, legacy remains archived — nothing deleted
    assert File.exists?(Path.join(ws, "data/browser-sessions/news/profile.db"))
    assert File.dir?(Path.join(ws, "archive/workspace-legacy.git"))
    assert File.exists?(Path.join(ws, "archive/agents/orphan/HEARTBEAT.md"))
    assert File.exists?(Path.join(ws, "archive/plugins/unclaimed/README.md"))
    refute File.dir?(Path.join(ws, ".git"))

    # Snapshot exported with canonical remapping
    snapshot =
      ws |> Path.join("data/risk-manifest-snapshot.json") |> File.read!() |> Jason.decode!()

    assert %{"taint_level" => "high", "sensitivity_level" => "medium"} =
             snapshot["agents/news/NOTES.md"]

    assert Map.has_key?(snapshot, "shared/core/AGENTS.md")
    assert Map.has_key?(snapshot, "shared/knowledge/obsidian/shared/index.md")

    # Idempotent: a second run is a no-op, not a crash
    Mix.Task.rerun("tri_onyx.migrate_repos", [])
  end
end
