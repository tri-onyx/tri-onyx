# Security hunter ledger

- 2026-11-27 | FIXED     | repo-store  | Label SubmitPage commits with the session's taint/sensitivity | lib/tri_onyx/workspace.ex
- 2026-11-27 | NO-FINDING| repo-store  | Swept bare_dir/tree_dir/gitdir composition (names come from admin-owned definitions), read_file_at_commit (SHA regex, git-scoped paths), refresh_ro/clean, park_conflict, merge recovery, GitProvenance override parsing, RiskManifest rebuild. Symlink-following (#64/#71/#75/#76/#83), pathspec magic (#86), nested .git (#87), trailer forging (#39), sweeper ordering (#89), canonical `..` (#42/#62) already have open PRs |
- 2026-11-27 | DOWNGRADED| repo-store  | An agent named `_ro`/`_gw`, or a shared repo named `self`, collides with RepoStore's reserved tree/gitdir paths (`trees/_ro/<repo>`, `trees/<agent>/self`). Only reachable via an admin-written definition, so not a sandbox finding; consider reserving these names in AgentDefinition validation | lib/tri_onyx/repo_store.ex
