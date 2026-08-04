# Architecture Decisions

This page indexes the Architecture Decision Records (ADRs) and key design documents for TriOnyx.

## Design Documents

| Document | Description |
|----------|-------------|
| [Security Model](https://github.com/tri-onyx/tri-onyx/blob/main/adr/SECURITY_MODEL.md) | Three-axis risk model (taint, sensitivity, capability), enforcement layers, violation detection |
| [Architecture](https://github.com/tri-onyx/tri-onyx/blob/main/adr/ARCHITECTURE.md) | System architecture overview |

## Architecture Decision Records

| ADR | Decision |
|-----|----------|
| [001](https://github.com/tri-onyx/tri-onyx/blob/main/adr/001-information-is-the-threat.md) | Information is the threat, not capability |
| [002](https://github.com/tri-onyx/tri-onyx/blob/main/adr/002-elixir-gateway.md) | Elixir/OTP for the gateway |
| [003](https://github.com/tri-onyx/tri-onyx/blob/main/adr/003-python-agent-runtime.md) | Python for the agent runtime and connector |
| [004](https://github.com/tri-onyx/tri-onyx/blob/main/adr/004-go-fuse-driver.md) | Go FUSE driver for filesystem policy enforcement *(superseded by 012)* |
| [005](https://github.com/tri-onyx/tri-onyx/blob/main/adr/005-bandwidth-constrained-trust.md) | Bandwidth restriction as taint containment |
| [006](https://github.com/tri-onyx/tri-onyx/blob/main/adr/006-gateway-credential-secrecy.md) | Gateway as sole credential holder with automatic sensitivity |
| [007](https://github.com/tri-onyx/tri-onyx/blob/main/adr/007-biba-blp-violation-detection.md) | Independent Biba and Bell-LaPadula violation detection |
| [008](https://github.com/tri-onyx/tri-onyx/blob/main/adr/008-risk-manifest-provenance.md) | Risk manifest for file-level provenance tracking |
| [009](https://github.com/tri-onyx/tri-onyx/blob/main/adr/009-graph-analysis-transitive-risk.md) | Graph analysis for transitive risk propagation |
| [010](https://github.com/tri-onyx/tri-onyx/blob/main/adr/010-lethal-trifecta.md) | The lethal trifecta -- taint, sensitivity, and capability |
| [011](https://github.com/tri-onyx/tri-onyx/blob/main/adr/011-track-and-kill-enforcement.md) | Track-and-kill risk enforcement -- reads escalate, exceeding the ceiling kills |
| 012 | Per-agent git repositories as the isolation boundary -- FUSE driver retired |

### ADR 012 — Per-agent git repositories as the isolation boundary (2026-08-04)

**Decision.** Filesystem isolation moves from the custom Go FUSE driver
(ADR 004) to per-agent git repositories enforced by kernel bind mounts —
"the mount set is the ACL":

- **Per-agent repos.** Each agent owns a git repository, mounted read-write at
  `/workspace` (its working directory). Memory files live directly in it
  (`NOTES.md`, `memory/<date>.md`, `HEARTBEAT.md`, `reflections/`).
- **Shared repos.** `core` (AGENTS.md + personality), `definitions` (agent
  definitions), and `knowledge` (obsidian vaults + shared plugins) mount at
  `/repos/<name>` — read-write via the `repos_write` definition field,
  read-only via `repos_read` (values: shared names, `agents/<name>`, or the
  wildcard `agents/*`). These fields replace `fs_read`/`fs_write`.
- **FUSE retired.** The `fuse/` tree and `tri-onyx-fs` binary are deleted.
  Agent containers no longer need `SYS_ADMIN`, `/dev/fuse`, or AppArmor
  overrides. What isn't mounted doesn't exist inside the container.
- **Gateway-only git.** Working trees contain no `.git`. At session end the
  gateway commits each session's changes per repo with `Taint-Level`/
  `Sensitivity-Level` provenance trailers and pushes to the bare repo.
- **Clone-per-agent sync.** Bare repos under `workspace/bare/` are the source
  of truth; the gateway manages working trees under `workspace/trees/`
  (`trees/<agent>/self`, `trees/_ro/...`, `trees/_gw/...`). Read-only mounts
  show last-committed state; shared-repo write conflicts are parked on
  `conflict/<agent>/<session>` branches.

**Consequences.** The security boundary is a kernel primitive instead of a
custom driver; per-session provenance commits replace FUSE access logging as
the audit trail for file changes; fresh installs are seeded from
`workspace.template/` by the gateway at startup; existing single-repo
workspaces migrate via `mix tri_onyx.migrate_repos` (supports `--dry-run`,
archives the legacy repo under `workspace/archive/` and snapshots the risk
manifest to `workspace/data/risk-manifest-snapshot.json`). ADR 004 and the
[FUSE driver spec](fuse-driver-spec.md) are historical.
