# ADR-011: Track-and-Kill Risk Enforcement

**Status:** Accepted
**Date:** 2026-06-09

## Context

The security model's promise is information-flow tracking: every agent
session carries taint and sensitivity levels reflecting everything it has
seen, and enforcement responds to the *combination* of exposure and
capability rather than restricting individual operations.

Before this ADR, three links in that loop were missing or contradicted it:

1. **No read-side tracking.** The FUSE driver reported writes but not
   reads, so a session that read another agent's tainted output never
   escalated. The only protections were static graph analysis and glob
   policy.
2. **Provenance arrived too late.** Files written via Bash/Python only got
   risk-manifest labels at session end (`commit_workspace_writes`), leaving
   a window of minutes during which concurrent sessions read unlabeled
   files (TODO entry from 2026-03-15).
3. **Read filtering contradicted the model.** The Go driver contained a
   risk-based read-denial feature (`max_read_taint` / `max_read_sensitivity`
   checked against a mount-time manifest snapshot). It was dead code — the
   definition schema never had the fields, the gateway never emitted them,
   and `main.go` never wired them — but more importantly it embodied the
   wrong philosophy: blocking reads is capability sandboxing, not
   information-flow tracking.

## Decision

**Reads are unlimited. Reading escalates. Exceeding the ceiling kills.**

1. **FUSE reports reads.** A `log_reads` policy flag (always enabled by the
   gateway) makes the driver emit a JSON read event for every open whose
   access mode permits reading. Events are deduplicated per path per mount —
   escalation is monotonic, so repeats carry no information.

2. **Writes label immediately, commits debounce.** `Workspace.Committer` is
   the single owner of incremental workspace git operations. On each write
   event it synchronously updates the risk manifest with the writing
   session's taint/sensitivity *at write time* (point-in-time labels), then
   commits coalesced batches on a ~5s debounce, one commit per
   (agent, session, labels) group with provenance trailers. This closes the
   provenance window, makes labels more precise than the old session-end
   bulk labeling (which stamped every file with the session's final,
   highest levels), survives session crashes, and eliminates the
   index-lock races of multiple concurrent git writers. The per-write
   `GitProvenance.record_write` path for Write/Edit tools was removed as
   redundant — FUSE write events cover those writes.

3. **Reads escalate the reader.** The gateway resolves each read event
   against the risk manifest and escalates the reading session's taint and
   sensitivity to the file's recorded labels at **full strength**. The
   per-hop sensitivity decay used in worst-case graph analysis does not
   apply: reading raw file content is direct disclosure, not a summary by
   an intermediary. Reads of unlabeled files (predating this mechanism, or
   operator-created) are a no-op recorded in the audit log as
   `unclassified_read`.

4. **Kill on threshold.** Agent definitions gain `max_effective_risk`
   (`low` / `moderate` / `high` / `critical`, default `critical`). When an
   escalation pushes effective risk above the ceiling, the session is
   killed immediately — mid-turn, no grace period — and sessions whose
   initial classification already exceeds the ceiling are refused at start.
   The default of `critical` can never be exceeded, so enforcement is
   opt-in per agent.

5. **Read filtering removed.** The dead `max_read_*` chain was deleted from
   the Go driver, policy parser, and sandbox config.

## Consequences

- The lethal-trifecta loop is closed at runtime: exposure is tracked at
  the syscall boundary, labels are fresh within milliseconds of a write,
  and the response to excessive risk is termination, not capability
  juggling ("kill, don't downgrade").
- Labels are point-in-time, so files written early in a session that
  later escalates are no longer over-labeled.
- Per-write manifest updates plus debounced commits trade a small amount
  of commit granularity for bounded git churn; the `Workspace.Sweeper`
  remains the backstop for anything left over after crashes.
- Known modeling discrepancy: the graph analyzer still applies per-hop
  sensitivity decay on filesystem edges, slightly understating worst-case
  sensitivity relative to the new runtime behavior. Aligning the analyzer
  is follow-up work.
- Existing workspace files have no manifest entries until they are next
  written; reads of them do not escalate. The audit log's
  `unclassified_read` entries make the size of this tail visible.
