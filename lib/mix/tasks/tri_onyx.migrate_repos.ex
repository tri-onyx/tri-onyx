defmodule Mix.Tasks.TriOnyx.MigrateRepos do
  @shortdoc "Migrates the legacy single-repo workspace to per-agent repos"

  @moduledoc """
  One-shot migration from the legacy shared-workspace layout (one git
  repo for everything) to the per-agent repo layout managed by
  `TriOnyx.RepoStore`.

      $ mix tri_onyx.migrate_repos [--dry-run]

  What it does, in order:

  1. Exports a risk-manifest snapshot from the legacy repo's git history
     to `data/risk-manifest-snapshot.json`, with paths remapped to
     canonical form (`agents/<name>/...`, `shared/<name>/...`).
  2. For every agent with a definition file: creates a bare repo +
     working tree, MOVES `agents/<name>/` content into it (plus the
     plugins that agent solely owns, into `plugins/<plugin>/`), writes a
     `.gitignore`, and commits + pushes an import commit.
  3. Creates the shared repos: `core` (personality/ + AGENTS.md),
     `definitions` (agent-definitions/), `knowledge` (obsidian/ + plugins
     declared by more than one agent).
  4. Moves non-repo data: `browser-sessions/` → `data/browser-sessions/`,
     `repos/` → `data/github/`, `repos-ro/` → `data/github-ro/`,
     `data/introspection/` → the introspector agent repo.
  5. Archives everything else — the legacy `.git`, `.tri-onyx/`,
     `plugins.yaml`, and agent dirs without a definition — under
     `archive/`. NOTHING IS DELETED; every step is a rename.

  The task is idempotent: repos that already exist are skipped, so a
  failed run can be re-executed.
  """

  use Mix.Task

  alias TriOnyx.AgentDefinition
  alias TriOnyx.RepoStore

  @agent_gitignore """
  __pycache__/
  .venv/
  .playwright-cli/
  *.pyc
  """

  @knowledge_gitignore """
  .obsidian/
  __pycache__/
  .venv/
  *.pyc
  """

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.config")
    dry_run = "--dry-run" in args

    ws = RepoStore.root()
    legacy_git = Path.join(ws, ".git")

    unless File.dir?(legacy_git) or File.dir?(Path.join(ws, "archive/workspace-legacy.git")) do
      Mix.shell().error("No legacy workspace repo at #{legacy_git} — nothing to migrate.")
      exit({:shutdown, 1})
    end

    definitions = load_definitions(Path.join(ws, "agent-definitions"))
    agent_names = Enum.map(definitions, & &1.name)
    {owned_plugins, shared_plugins} = plugin_ownership(definitions)

    Mix.shell().info("Workspace:      #{Path.expand(ws)}")
    Mix.shell().info("Agents:         #{Enum.join(agent_names, ", ")}")

    Mix.shell().info(
      "Owned plugins:  " <>
        Enum.map_join(owned_plugins, ", ", fn {p, a} -> "#{p}→#{a}" end)
    )

    Mix.shell().info("Shared plugins: #{Enum.join(shared_plugins, ", ")} (→ knowledge)")
    if dry_run, do: Mix.shell().info("\n--dry-run: no changes will be made.\n")

    steps = [
      {"export risk-manifest snapshot", fn -> export_snapshot(ws) end},
      {"migrate agent repos",
       fn -> Enum.each(agent_names, &migrate_agent(ws, &1, owned_plugins)) end},
      {"create core repo", fn -> migrate_core(ws) end},
      {"create definitions repo", fn -> migrate_definitions(ws) end},
      {"create knowledge repo", fn -> migrate_knowledge(ws, shared_plugins) end},
      {"relocate non-repo data", fn -> relocate_data(ws, agent_names) end},
      {"archive legacy remains", fn -> archive_legacy(ws, agent_names) end}
    ]

    Enum.each(steps, fn {label, fun} ->
      Mix.shell().info("==> #{label}")
      unless dry_run, do: fun.()
    end)

    Mix.shell().info("\nMigration #{if dry_run, do: "plan printed", else: "complete"}.")

    unless dry_run do
      Mix.shell().info("""

      Next steps:
        - point TRI_ONYX_AGENTS_DIR at #{Path.join(ws, "trees/_gw/definitions")}
        - restart the gateway
        - verify: mix tri_onyx.status
      """)
    end
  end

  # --- Definitions & plugin ownership ---

  defp load_definitions(dir) do
    case Path.wildcard(Path.join(dir, "*.md")) do
      [] ->
        # Definitions may already have been migrated into the repo tree.
        migrated = Path.join([RepoStore.root(), "trees", "_gw", "definitions"])
        Path.wildcard(Path.join(migrated, "*.md")) |> parse_definitions()

      files ->
        parse_definitions(files)
    end
  end

  defp parse_definitions(files) do
    Enum.flat_map(files, fn file ->
      case file |> File.read!() |> AgentDefinition.parse() do
        {:ok, definition} ->
          [definition]

        {:error, reason} ->
          Mix.shell().error("  skipping unparseable #{Path.basename(file)}: #{inspect(reason)}")
          []
      end
    end)
  end

  # The knowledgebase plugin is shared between youtube, news and wiki by
  # design — route it to the knowledge repo even when no live definition
  # currently declares it (the knowledgebase agent may be template-only).
  @force_shared_plugins ~w(knowledgebase)

  # A plugin declared by exactly one agent belongs to that agent's repo;
  # plugins declared by several agents (or force-listed) go to the shared
  # knowledge repo.
  defp plugin_ownership(definitions) do
    declarations =
      definitions
      |> Enum.flat_map(fn d -> Enum.map(d.plugins, &{&1, d.name}) end)
      |> Enum.group_by(fn {p, _} -> p end, fn {_, a} -> a end)

    owned =
      for {plugin, [single_owner]} <- declarations,
          plugin not in @force_shared_plugins,
          into: %{} do
        {plugin, single_owner}
      end

    multi = for {plugin, [_, _ | _]} <- declarations, do: plugin
    {owned, Enum.uniq(multi ++ @force_shared_plugins)}
  end

  # --- Snapshot export ---

  defp export_snapshot(ws) do
    snapshot_path = Path.join(ws, "data/risk-manifest-snapshot.json")
    legacy_git = legacy_git_dir(ws)

    cond do
      File.exists?(snapshot_path) ->
        Mix.shell().info("  snapshot already exists, skipping")

      is_nil(legacy_git) ->
        Mix.shell().error("  no legacy git dir found, skipping snapshot")

      true ->
        {output, 0} =
          System.cmd(
            "git",
            [
              "-c",
              "safe.directory=*",
              "--git-dir",
              legacy_git,
              "log",
              "--no-renames",
              "--name-status",
              "--format=#{TriOnyx.RiskManifest.log_format()}"
            ],
            stderr_to_stdout: false
          )

        entries =
          output
          |> TriOnyx.RiskManifest.rebuild_entries("")
          |> Enum.flat_map(fn {path, entry} ->
            case remap_legacy_path(path) do
              nil -> []
              canonical -> [{canonical, entry}]
            end
          end)
          |> Map.new()

        File.mkdir_p!(Path.dirname(snapshot_path))
        File.write!(snapshot_path, Jason.encode!(entries, pretty: true))
        Mix.shell().info("  exported #{map_size(entries)} entries to #{snapshot_path}")
    end
  end

  # Maps a legacy workspace-relative path to its canonical post-split
  # path. Returns nil for paths that have no home in the new layout.
  # NOTE: plugin remapping here is layout-based (all plugins move under a
  # repo's plugins/ dir); ownership is resolved at lookup time by prefix,
  # so we emit both possible homes for plugin paths.
  defp remap_legacy_path("agents/" <> _ = path), do: path
  defp remap_legacy_path("personality/" <> _ = path), do: "shared/core/#{path}"
  defp remap_legacy_path("AGENTS.md"), do: "shared/core/AGENTS.md"
  defp remap_legacy_path("agent-definitions/" <> rest), do: "shared/definitions/#{rest}"
  defp remap_legacy_path("obsidian/" <> _ = path), do: "shared/knowledge/#{path}"
  defp remap_legacy_path(_), do: nil

  defp legacy_git_dir(ws) do
    cond do
      File.dir?(Path.join(ws, ".git")) -> Path.join(ws, ".git")
      File.dir?(Path.join(ws, "archive/workspace-legacy.git")) -> Path.join(ws, "archive/workspace-legacy.git")
      true -> nil
    end
  end

  # --- Agent repos ---

  defp migrate_agent(ws, name, owned_plugins) do
    repo = {:agent, name}

    if RepoStore.exists?(repo) do
      Mix.shell().info("  #{name}: repo exists, skipping")
    else
      :ok = RepoStore.ensure_tree(name, repo)
      tree = RepoStore.tree_dir(name, repo)

      moved = move_dir_contents(Path.join([ws, "agents", name]), tree)

      plugin_moves =
        for {plugin, ^name} <- owned_plugins do
          src = Path.join([ws, "plugins", plugin])
          dst = Path.join([tree, "plugins", plugin])
          if File.dir?(src), do: move_tree(src, dst)
          plugin
        end

      gitignore = Path.join(tree, ".gitignore")
      unless File.exists?(gitignore), do: File.write!(gitignore, agent_gitignore(name, plugin_moves))

      case RepoStore.commit_and_push(name, repo,
             author: "migration",
             message: "chore: import #{name} from legacy workspace",
             session_id: "migration"
           ) do
        {:ok, sha} when is_binary(sha) ->
          Mix.shell().info("  #{name}: #{moved} entries imported (#{String.slice(sha, 0, 10)})")

        {:ok, :no_changes} ->
          Mix.shell().info("  #{name}: empty import")

        other ->
          Mix.raise("agent #{name} import failed: #{inspect(other)}")
      end
    end
  end

  defp agent_gitignore(_name, plugin_moves) do
    extra =
      if "newsagg" in plugin_moves do
        "plugins/newsagg/cache/\nplugins/newsagg/seen.txt\n"
      else
        ""
      end

    @agent_gitignore <> extra
  end

  # --- Shared repos ---

  defp migrate_core(ws) do
    migrate_shared(ws, "core", fn tree ->
      moved = 0
      moved = moved + if File.dir?(Path.join(ws, "personality")), do: move_tree(Path.join(ws, "personality"), Path.join(tree, "personality")), else: 0

      agents_md = Path.join(ws, "AGENTS.md")

      moved =
        if File.regular?(agents_md) do
          File.rename!(agents_md, Path.join(tree, "AGENTS.md"))
          moved + 1
        else
          moved
        end

      moved
    end)
  end

  defp migrate_definitions(ws) do
    migrate_shared(ws, "definitions", fn tree ->
      src = Path.join(ws, "agent-definitions")
      if File.dir?(src), do: move_dir_contents(src, tree), else: 0
    end)
  end

  defp migrate_knowledge(ws, shared_plugins) do
    migrate_shared(ws, "knowledge", fn tree ->
      moved =
        if File.dir?(Path.join(ws, "obsidian")) do
          move_tree(Path.join(ws, "obsidian"), Path.join(tree, "obsidian"))
        else
          0
        end

      moved =
        Enum.reduce(shared_plugins, moved, fn plugin, acc ->
          src = Path.join([ws, "plugins", plugin])

          if File.dir?(src) do
            acc + move_tree(src, Path.join([tree, "plugins", plugin]))
          else
            acc
          end
        end)

      gitignore = Path.join(tree, ".gitignore")
      unless File.exists?(gitignore), do: File.write!(gitignore, @knowledge_gitignore)
      moved
    end)
  end

  defp migrate_shared(ws, name, populate) do
    repo = {:shared, name}

    if RepoStore.exists?(repo) and not legacy_content_pending?(ws, name) do
      Mix.shell().info("  #{name}: repo exists, skipping")
    else
      :ok = RepoStore.ensure_tree(:gw, repo)
      :ok = RepoStore.sync_tree(:gw, repo)
      tree = RepoStore.tree_dir(:gw, repo)
      moved = populate.(tree)

      case RepoStore.commit_and_push(:gw, repo,
             author: "migration",
             message: "chore: import #{name} from legacy workspace",
             session_id: "migration"
           ) do
        {:ok, sha} when is_binary(sha) ->
          Mix.shell().info("  #{name}: #{moved} entries imported (#{String.slice(sha, 0, 10)})")

        {:ok, :no_changes} ->
          Mix.shell().info("  #{name}: nothing new to import")

        other ->
          Mix.raise("shared repo #{name} import failed: #{inspect(other)}")
      end
    end
  end

  # True when legacy source content for this shared repo still sits in the
  # old location (a previous run may have created the repo but died before
  # the move).
  defp legacy_content_pending?(ws, "core"),
    do: File.dir?(Path.join(ws, "personality")) or File.regular?(Path.join(ws, "AGENTS.md"))

  defp legacy_content_pending?(ws, "definitions"), do: File.dir?(Path.join(ws, "agent-definitions"))
  defp legacy_content_pending?(ws, "knowledge"), do: File.dir?(Path.join(ws, "obsidian"))
  defp legacy_content_pending?(_ws, _), do: false

  # --- Non-repo data ---

  defp relocate_data(ws, agent_names) do
    File.mkdir_p!(Path.join(ws, "data"))

    rename_if_exists(ws, "browser-sessions", "data/browser-sessions")
    rename_if_exists(ws, "repos", "data/github")
    rename_if_exists(ws, "repos-ro", "data/github-ro")

    # Introspection data belongs to the introspector agent's repo.
    introspection = Path.join(ws, "data/introspection")

    if File.dir?(introspection) and "introspector" in agent_names do
      tree = RepoStore.tree_dir("introspector", {:agent, "introspector"})

      if File.dir?(tree) do
        move_tree(introspection, Path.join(tree, "introspection"))

        RepoStore.commit_and_push("introspector", {:agent, "introspector"},
          author: "migration",
          message: "chore: import introspection data from legacy workspace",
          session_id: "migration"
        )
      end
    end
  end

  # --- Archive ---

  defp archive_legacy(ws, agent_names) do
    archive = Path.join(ws, "archive")
    File.mkdir_p!(archive)

    rename_if_exists(ws, ".git", "archive/workspace-legacy.git")
    rename_if_exists(ws, ".tri-onyx", "archive/tri-onyx-state")
    rename_if_exists(ws, "plugins.yaml", "archive/plugins.yaml")
    rename_if_exists(ws, ".gitignore", "archive/workspace-gitignore")

    # Leftover plugins (declared by nobody) and orphaned agent dirs.
    rename_if_exists(ws, "plugins", "archive/plugins")

    agents_dir = Path.join(ws, "agents")

    if File.dir?(agents_dir) do
      File.mkdir_p!(Path.join(archive, "agents"))

      agents_dir
      |> File.ls!()
      |> Enum.each(fn entry ->
        src = Path.join(agents_dir, entry)

        if entry in agent_names and empty_dir?(src) do
          # Migrated agent: only an empty husk remains.
          File.rmdir(src)
        else
          File.rename!(src, Path.join([archive, "agents", entry]))
          Mix.shell().info("  archived agents/#{entry}")
        end
      end)

      if empty_dir?(agents_dir), do: File.rmdir(agents_dir)
    end
  end

  # --- File helpers (rename-only, no deletion) ---

  defp rename_if_exists(ws, from, to) do
    src = Path.join(ws, from)
    dst = Path.join(ws, to)

    if File.exists?(src) and not File.exists?(dst) do
      File.mkdir_p!(Path.dirname(dst))
      File.rename!(src, dst)
      Mix.shell().info("  moved #{from} → #{to}")
    end
  end

  # Moves every entry of src into dst (dst may already contain the
  # freshly-cloned tree scaffolding). Returns the number of entries moved.
  defp move_dir_contents(src, dst) do
    if File.dir?(src) do
      File.mkdir_p!(dst)

      src
      |> File.ls!()
      |> Enum.reduce(0, fn entry, acc ->
        File.rename!(Path.join(src, entry), Path.join(dst, entry))
        acc + 1
      end)
    else
      0
    end
  end

  # Moves an entire directory to a destination path. When the destination
  # already exists (e.g. template files seeded by ensure_initialized),
  # merges recursively — legacy content wins over templates, since a
  # plain rename replaces files but fails on existing directories.
  defp move_tree(src, dst) do
    File.mkdir_p!(Path.dirname(dst))

    if File.dir?(dst) do
      src
      |> File.ls!()
      |> Enum.each(fn entry ->
        entry_src = Path.join(src, entry)
        entry_dst = Path.join(dst, entry)

        if File.dir?(entry_src) and File.dir?(entry_dst) do
          move_tree(entry_src, entry_dst)
        else
          File.rename!(entry_src, entry_dst)
        end
      end)

      File.rmdir(src)
    else
      File.rename!(src, dst)
    end

    1
  end

  defp empty_dir?(path) do
    case File.ls(path) do
      {:ok, []} -> true
      _ -> false
    end
  end
end
