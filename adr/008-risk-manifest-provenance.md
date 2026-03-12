# ADR-008: Risk Manifest for File-Level Provenance Tracking

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Falense

## Context

TriOnyx agents share a workspace through the filesystem. Agent A writes a file; Agent B reads it. The security model ([ADR-001](001-information-is-the-threat.md)) requires that B's taint and sensitivity levels escalate to match A's levels when B reads the file. The FUSE driver ([ADR-004](004-go-fuse-driver.md)) enforces read restrictions based on taint and sensitivity thresholds. The violation detector ([ADR-007](007-biba-blp-violation-detection.md)) flags dangerous data flows between agents.

All three mechanisms need the same thing: **per-file metadata recording which agent wrote each file and what that agent's taint and sensitivity levels were at the time of writing.** Without this, the FUSE driver cannot enforce risk-based read restrictions, the violation detector cannot determine whether a file flow violates Biba or BLP, and taint/sensitivity propagation through the filesystem is blind.

The system also needs provenance history. When an incident occurs, operators need to trace how a file's risk changed over time, which agents modified it, and whether a human reviewed it. This history must survive across sessions and be auditable.

## Decision

Maintain a **risk manifest** at `.tri-onyx/risk-manifest.json` in the workspace root that records per-file taint level, sensitivity level, writing agent, and timestamp. Embed **Git commit trailers** (`Taint-Level:`, `Sensitivity-Level:`) on every workspace commit to preserve provenance in version control history. Support **human review** as a mechanism to reset taint to low on reviewed files.

## Rationale

### Per-file metadata enables fine-grained enforcement

Agent-level taint and sensitivity are coarse: "agent A is high-taint" says nothing about which files are safe to read. An agent might produce 50 files, most derived from trusted sources, with only 3 derived from untrusted input. The risk manifest tags each file individually, allowing the FUSE driver to permit reads of the 47 safe files while denying reads of the 3 tainted files.

In practice, the current implementation tags all files written by an agent with that agent's session-level taint and sensitivity, because LLM taint propagation is total within a session ([ADR-001](001-information-is-the-threat.md)). The per-file structure exists to support future refinement if partial taint tracking becomes feasible, and to record the writing agent's identity for audit purposes.

### JSON manifest is the live state; Git trailers are the audit trail

The risk manifest serves two audiences:

1. **Runtime consumers** (FUSE driver, graph analyzer) need fast, structured lookups. A JSON file with path keys is the simplest format that supports O(1) lookups by path.

2. **Auditors and incident responders** need historical provenance. The risk manifest is overwritten on each session — it reflects current state, not history. Git commit trailers embed the taint and sensitivity levels at commit time into the version control history, which is append-only and tamper-evident (assuming standard Git integrity).

The manifest entry for a file:

```json
{
  "path/to/file": {
    "taint_level": "high",
    "sensitivity_level": "medium",
    "risk_level": "high",
    "agent": "web-scraper",
    "updated_at": "2026-02-17T10:30:00Z"
  }
}
```

The corresponding Git commit:

```
web-scraper session abc-123

Taint-Level: high
Sensitivity-Level: medium
```

`risk_level` is `max(taint_level, sensitivity_level)` for backward compatibility with single-axis consumers.

### Human review resets taint but not sensitivity

A human reviewing and approving an artifact resets its taint to low. The rationale:

- **Taint tracks trustworthiness** — whether the content may contain adversarial manipulation. A human reviewer has judged the content safe, removing the prompt injection concern. Taint drops to low.
- **Sensitivity tracks data sensitivity** — whether the content contains non-public or sensitive data. Rephrasing a database record does not make it less sensitive. A human approving a summary of PII does not declassify the PII. Sensitivity is unchanged.

The manifest records the review:

```json
{
  "path/to/file": {
    "taint_level": "low",
    "sensitivity_level": "medium",
    "risk_level": "medium",
    "agent": "web-scraper",
    "updated_at": "2026-02-17T10:30:00Z",
    "reviewed_by": "falense",
    "reviewed_at": "2026-02-17T11:00:00Z"
  }
}
```

A separate Git commit records the review with `Taint-Level: low`, creating an audit trail showing who reviewed what and when.

### Merge strategy is last-writer-wins

When a session completes, the gateway reads the current manifest, merges the session's written paths (overwriting entries for the same path), and writes it back. This means the manifest always reflects the most recent write to each path. Historical entries are available through Git history.

This is simple and correct for the common case: if agent A writes `output.txt` and later agent B overwrites it, the manifest should reflect B's risk levels, not A's.

### The manifest lives in the workspace, not the gateway

Storing the manifest alongside the files it describes means:

- The FUSE driver can read it from the source directory without a network call to the gateway
- It is versioned in Git alongside the files, keeping provenance and content in sync
- It is available to any tool that reads the workspace (graph analyzer, dashboards, CI checks)

## Alternatives Considered

### Extended file attributes (xattr)

Store taint and sensitivity as filesystem extended attributes on each file. Elegant — metadata travels with the file. However, xattr support varies across filesystems, is lost on many copy operations, is not preserved by Git, and the FUSE driver would need to intercept `getxattr`/`setxattr` syscalls. A sidecar JSON file is portable and Git-friendly.

### Database-backed provenance store

Store file metadata in a database (SQLite, PostgreSQL) rather than a JSON file. Better query support and concurrent access. However, adds a database dependency to the agent container (for FUSE reads) or requires the FUSE driver to call the gateway over a network API. The JSON manifest is self-contained and requires no additional infrastructure.

### Embed metadata in file headers

Prepend a metadata block to each file (like YAML frontmatter). Preserves metadata with the file content. However, modifies the file content (breaking checksums, confusing parsers), does not work for binary files, and requires every consumer to understand the header format. A sidecar file is non-invasive.

### No manifest — infer risk from agent definitions

Use the writing agent's worst-case taint and sensitivity (from its definition) rather than tracking actual session-level risk. Simpler but less accurate: an agent defined with WebFetch access might not have used it in a given session, making its actual taint lower than worst-case. The manifest records what actually happened, not what could have happened.

## Consequences

- **Positive:** The FUSE driver, graph analyzer, and violation detector share a single source of truth for per-file risk metadata. No divergence between components.
- **Positive:** Git commit trailers create a tamper-evident audit trail of risk provenance without additional infrastructure.
- **Positive:** Human review provides a principled mechanism for taint reduction that preserves sensitivity — the only way to make tainted data safe for clean agents without BCP.
- **Negative:** The JSON manifest is a single file modified by every session completion. Concurrent sessions writing to the same workspace could race on manifest updates. Mitigated by the gateway serializing workspace commits per workspace.
- **Negative:** The manifest grows linearly with the number of unique file paths written across all sessions. For long-lived workspaces with many files, the manifest becomes large. Mitigated by periodic pruning of entries for deleted files.
- **Accepted trade-off:** The manifest records session-level taint/sensitivity per file, not per-line or per-block. An agent that is high-taint due to one tool call has all its file writes tagged as high-taint, even files unrelated to the tainted data. This is the conservative consequence of total taint propagation within LLM contexts — there is no way to know which outputs were influenced by which inputs.
