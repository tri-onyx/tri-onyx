# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-04 | FIXED | repo-store | Workspace.canonical_path/2 didn't normalize traversal (`/workspace/../repos/<repo>/<file>`) before mapping to canonical form, letting a Read of an already-mounted, already-labeled sensitive file be classified `:low` instead of its real recorded sensitivity | lib/tri_onyx/workspace.ex
