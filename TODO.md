# TODO

## Provenance gap: delayed taint/sensitivity propagation via filesystem

**Status:** Open
**Found:** 2026-03-15

### Bug: `commit_session` fails when FUSE-tracked files are deleted before session end

`commit_workspace_writes` passes all FUSE-tracked paths to a single `git add` call. If any file was created and deleted during the session (e.g., news agent's incoming article review pipeline: fetch → `/incoming/` → review → delete), `git add` fails with exit 128 (`pathspec did not match any files`) and **zero files get committed**. This is the root cause of 2,168 untracked files in the workspace.

**Fix:** Filter out nonexistent paths before `git add`, or use `git add --ignore-missing`, or add files individually. See `lib/tri_onyx/workspace.ex:145`.

### Design issue: provenance window between FUSE write and session commit

Files written via Bash/Python (not Write/Edit tools) only get provenance metadata at session end via Path 2 (`commit_workspace_writes`). Until the session completes, these files exist on disk with **no taint/sensitivity metadata** in the risk manifest or git history.

If another agent reads such a file during this window (via overlapping fs_read/fs_write policies), the FUSE driver finds no manifest entry and treats it as unclassified. The reading agent's taint/sensitivity does not escalate, and taint propagation is silently skipped.

**Two commit paths:**
1. **Path 1 (`record_write`):** Fires immediately per-file for Write/Edit/NotebookEdit tool calls. Full provenance committed inline.
2. **Path 2 (`commit_workspace_writes`):** Fires at session end for all FUSE-tracked writes. Bulk commit with session-level taint/sensitivity.

Files only covered by Path 2 have a provenance gap from write time to session end. For long-running sessions (news agent: 5-30 min), this window can be significant.

**Potential fix:** Periodically flush `workspace_writes` during the session (e.g., after each tool result), or have the FUSE driver update the risk manifest directly on write.
