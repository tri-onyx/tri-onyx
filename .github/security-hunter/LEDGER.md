# Security hunter ledger

One line per entry, newest last. Statuses: FIXED, DOWNGRADED, NO-FINDING.

- 2026-11-23 | FIXED     | risk-model  | Sweep a crashed session's orphaned writes at the unlabeled floor before the next session claims the tree | lib/tri_onyx/repo_store.ex, lib/tri_onyx/repo_store/sweeper.ex
- 2026-11-23 | DOWNGRADED| risk-model  | Bash results ignore the agent's network policy (TaintMatrix says high, classifier returns low) — already open as #49/#63/#69/#78, needs one of them merged | lib/tri_onyx/information_classifier.ex
- 2026-11-23 | DOWNGRADED| risk-model  | Tools from plugin-provided MCP servers are unknown to TaintMatrix and default to :low taint even if they reach the network — needs a design decision (default-high for unknown tools?) | lib/tri_onyx/taint_matrix.ex
- 2026-11-23 | DOWNGRADED| risk-model  | RiskManifest replay keys git-quoted paths (non-ASCII/tab/quote names) verbatim, so per-file labels for such files are lost after a gateway restart (prefix read floor still holds) — consider `-z` / core.quotePath=false | lib/tri_onyx/risk_manifest.ex
