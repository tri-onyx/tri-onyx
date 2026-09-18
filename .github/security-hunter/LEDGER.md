# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-18 | FIXED | repo-store | park_conflict/5 hard-reset ANY principal's tree (including a live agent's own rw mount) onto origin after a parked push conflict, discarding uncommitted work the container held the only copy of, unlike recover_failed_merge/5 which already exempts agent-owned trees from this — lib/tri_onyx/repo_store.ex
- 2026-09-18 | NO-FINDING | repo-store | Reviewed canonical_path/2, resolve_canonical/1, agent_host_path/2, commit_page/2, GitProvenance.file_sensitivity/1 for the same class of bug already targeted by open PRs #39 (commit-message trailer forgery) and #42 (canonical_path traversal) — did not re-file. Checked RepoStore.Sweeper's do_sweep/0 (stale `active_principals/0` snapshot could let a tree become live mid-sweep) but could not build a deterministic repro distinct from the park_conflict finding above; the park_conflict fix also closes the worst outcome of that race (the sweep's own commit_and_push can no longer wipe the tree it's racing against). item_feedback.ex's confine/3 path resolution is fine (config-sourced dirs, not per-request attacker input).
