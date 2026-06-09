# TODO

## Provenance gap: delayed taint/sensitivity propagation via filesystem

**Status:** Open
**Found:** 2026-03-15

### Bug (FIXED): `commit_session` fails when FUSE-tracked files are deleted before session end

**Fixed 2026-03-15** in `8d2d57f`: `commit_session` filters out paths that no longer exist on disk (and ignored paths) before `git add` — see `lib/tri_onyx/workspace.ex:141-151`. The periodic workspace sweeper additionally catches strays with `git add -A`.

Original issue: `commit_workspace_writes` passed all FUSE-tracked paths to a single `git add` call; any file created and deleted during the session made `git add` fail with exit 128 and zero files committed.

### Design issue: provenance window between FUSE write and session commit

Files written via Bash/Python (not Write/Edit tools) only get provenance metadata at session end via Path 2 (`commit_workspace_writes`). Until the session completes, these files exist on disk with **no taint/sensitivity metadata** in the risk manifest or git history.

If another agent reads such a file during this window (via overlapping fs_read/fs_write policies), the FUSE driver finds no manifest entry and treats it as unclassified. The reading agent's taint/sensitivity does not escalate, and taint propagation is silently skipped.

**Two commit paths:**
1. **Path 1 (`record_write`):** Fires immediately per-file for Write/Edit/NotebookEdit tool calls. Full provenance committed inline.
2. **Path 2 (`commit_workspace_writes`):** Fires at session end for all FUSE-tracked writes. Bulk commit with session-level taint/sensitivity.

Files only covered by Path 2 have a provenance gap from write time to session end. For long-running sessions (news agent: 5-30 min), this window can be significant.

**Potential fix:** Periodically flush `workspace_writes` during the session (e.g., after each tool result), or have the FUSE driver update the risk manifest directly on write.
