# ADR-004: Go FUSE Driver for Filesystem-Level Policy Enforcement

- **Status:** Accepted
- **Date:** 2026-02-17
- **Deciders:** Sondre

## Context

TriOnyx's security model ([ADR-001](001-information-is-the-threat.md)) tracks information exposure across two axes: taint (integrity) and sensitivity (confidentiality). The gateway enforces these at the message-routing level, but agents also interact with the filesystem — reading files written by other agents, writing outputs that downstream agents consume. Without filesystem-level enforcement, an agent could bypass message-level controls by reading files it should not have access to, or a compromised agent could write to arbitrary paths.

The agent runtime runs inside a Docker container. Docker provides coarse-grained volume isolation (mount or don't mount), but TriOnyx needs fine-grained, per-path, per-agent access control based on glob patterns and risk metadata. The filesystem layer must:

- Allow or deny individual file reads based on glob patterns from the agent definition
- Allow or deny individual file writes based on separate glob patterns
- Deny reads of files whose taint or sensitivity levels exceed the agent's thresholds (using the risk manifest)
- Log all denials and writes as structured events for the gateway to consume
- Add negligible latency to filesystem operations
- Ship as a single binary with no runtime dependencies

## Decision

Implement the filesystem policy layer as a **FUSE (Filesystem in Userspace) driver written in Go**, using `hanwen/go-fuse/v2` for the FUSE protocol and `bmatcuk/doublestar/v4` for `**` glob matching.

## Rationale

### FUSE provides transparent, mandatory enforcement

FUSE interposes on kernel-level syscalls. The agent's Python process — and any child processes it spawns — cannot bypass the filesystem layer. Every `open()`, `read()`, `write()`, `create()`, `rename()`, and `mkdir()` call passes through the FUSE driver before reaching the underlying filesystem. This is mandatory access control at the OS level, not advisory checking in application code.

The agent sees `/workspace` as a normal filesystem. It does not need to know that FUSE is intercepting its calls. There is no agent-side SDK, no API to misuse, and no way to opt out.

### Pre-computed path trie gives O(1) access decisions

At startup, the driver expands all glob patterns against the source directory and builds a path trie — a tree structure where each node stores the access level (no access, traverse, read, write) for that path segment. Access checks are trie lookups, not glob matching per syscall. This makes the per-operation overhead constant regardless of the number of patterns.

The trie uses four access levels:

| Level | Meaning |
|-------|---------|
| `NoAccess` | Path not in any pattern — deny |
| `Traverse` | Intermediate directory needed to reach an allowed path — allow `readdir` and `stat`, deny `open` |
| `ReadAccess` | Matched by a read pattern — allow reads, deny writes |
| `WriteAccess` | Matched by a write pattern — allow reads and writes |

Access is monotonically promoted (a path matched by both read and write patterns gets `WriteAccess`), never downgraded.

### Risk manifest enables dynamic taint and sensitivity filtering

Static glob patterns control which paths an agent *could* access. The risk manifest (`.tri-onyx/risk-manifest.json`) controls which paths an agent *should* access based on the data provenance of each file. On every `Open()` call for a readable path, the driver checks:

1. If the file's `taint_level` exceeds the agent's `max_read_taint` threshold — deny with `EACCES`
2. If the file's `sensitivity_level` exceeds the agent's `max_read_sensitivity` threshold — deny with `EACCES`

Both axes are checked independently. A file that is low-taint but high-sensitivity is denied to an agent with `max_read_sensitivity: "low"`, even though the taint check passes. This enforces both Biba (integrity) and Bell-LaPadula (confidentiality) policies at the filesystem level as defense-in-depth behind the gateway's message-level checks.

### Structured event logging feeds the gateway

The driver emits JSON events to stderr:

**Write events** (when `log_writes` is enabled):
```json
{"event":"write","op":"create","path":"/repo/output.txt","time":"2026-02-13T12:00:00Z"}
```

**Denial events** (when `log_denials` is enabled):
```json
{"event":"denied","op":"open","path":"/repo/.env","mode":"read","time":"2026-02-13T12:00:00Z"}
```

The Elixir `AgentPort` captures these events from the container's stderr, and the `AgentSession` uses write events to track which files the agent has modified (for workspace commits on session completion). Denial events feed into audit logging.

### Go produces a single static binary

The FUSE driver compiles to one binary (`tri-onyx-fs`) with no shared library dependencies. It is copied into the agent container image at build time. There is no Go runtime to install, no dependency resolution at container start, and no version conflicts with the Python agent runtime. The binary is ~8 MB.

### Atomic write support for Claude Code patterns

Claude Code (and many editors) write files atomically: create `.filename.tmp`, write content, rename to `filename`. The driver's `expandWritePatterns` function generates companion patterns for these temp files automatically. A write pattern for `/repo/output.json` also permits `/repo/.output.json.*`, so atomic writes succeed without requiring the agent definition to anticipate editor behavior.

### Symlinks are unconditionally denied

The driver returns `ENOENT` for all symlink operations (`Readlink`, `Symlink`). This prevents symlink-based escape attacks where an agent creates a symlink pointing outside its allowed paths and then reads through it.

## Architecture

```
Agent Python Process
  │ open("/workspace/repo/src/main.py", O_RDONLY)
  ▼
Kernel FUSE layer
  │ dispatches to userspace
  ▼
tri-onyx-fs (Go binary, runs as root in container)
  ├─ Trie lookup: /repo/src/main.py → ReadAccess ✓
  ├─ Risk manifest check: taint=low ≤ max_read_taint=medium ✓
  ├─ Risk manifest check: sensitivity=low ≤ max_read_sensitivity=low ✓
  ├─ Passthrough: open /mnt/host/repo/src/main.py
  └─ Return file handle to kernel
```

The driver runs as root (required for FUSE mounting), but the agent process runs as the unprivileged `tri_onyx` user after `gosu` privilege drop. The `/mnt/host` bind mount is hidden from the agent by overmounting it with an empty tmpfs in a separate mount namespace via `unshare --mount`, preventing direct access that would bypass FUSE.

### Policy flow

1. **Agent definition** declares `fs_read` and `fs_write` glob patterns, plus `max_read_taint` and `max_read_sensitivity` thresholds
2. **Gateway** (`sandbox.ex`) builds a policy JSON and injects `/agents/<agent-name>/**` as a default write path
3. **Container entrypoint** writes the policy to `/etc/tri_onyx/fs-policy.json` and launches the FUSE driver
4. **FUSE driver** loads the policy, expands globs against `/mnt/host`, builds the trie, mounts at `/workspace`, and emits a `mounted` event with path counts
5. **Agent process** starts after FUSE is ready (entrypoint polls `mountpoint -q /workspace`)

## Alternatives Considered

### Docker volume mounts with multiple bind mounts

Docker supports mounting specific host paths. Could create one bind mount per allowed path. Does not scale to glob patterns (`**/*.py` would require enumerating every matching file as a separate mount). No support for risk-manifest-based dynamic filtering. No write event logging.

### eBPF-based filesystem filtering

eBPF programs can intercept filesystem syscalls at the kernel level with very low overhead. More performant than FUSE. However, eBPF requires elevated kernel capabilities, is harder to test (no userspace equivalent), has a steeper development curve, and the policy model (glob patterns + risk manifest) does not benefit from eBPF's performance — the bottleneck is LLM API latency, not filesystem access.

### Rust for the FUSE driver

Rust's `fuser` crate is capable but less mature than Go's `hanwen/go-fuse/v2`. The FUSE driver is a straightforward passthrough filesystem with access checks — it does not benefit from Rust's memory safety guarantees (no complex data structures, no concurrent mutation, no untrusted input parsing beyond the policy JSON). Go's simpler toolchain and faster compilation are more practical here.

### Python FUSE binding (`fusepy`)

Would keep the agent container as a single-language stack. However, `fusepy` is unmaintained, Python FUSE bindings add measurable latency per syscall (Python interpreter overhead on every file operation), and a Python FUSE process competing for the GIL with the agent runtime creates scheduling conflicts.

### Application-level access control (no FUSE)

Patch the agent runtime to check permissions before every file operation. Faster (no kernel round-trip), but advisory — any child process, shell command, or library call bypasses the checks. Not mandatory access control. A prompt-injected agent could be instructed to use raw syscalls or spawn a subprocess that ignores the checks.

## Consequences

- **Positive:** Mandatory, kernel-level enforcement that the agent cannot bypass. Every filesystem operation passes through the driver regardless of how it was initiated.
- **Positive:** The trie-based access model adds negligible overhead per operation. Agents do not experience perceptible filesystem latency from FUSE.
- **Positive:** Risk-manifest-based filtering enforces taint and sensitivity policies as defense-in-depth, independent of the gateway's message-level checks.
- **Positive:** Structured write and denial events give the gateway full visibility into filesystem activity without instrumenting the agent runtime.
- **Negative:** FUSE requires `SYS_ADMIN` capability and `/dev/fuse` device access in the container. This increases the container's privilege surface compared to a fully unprivileged container.
- **Negative:** Adds Go as a third language in the stack (alongside Elixir and Python). Mitigated by the driver being a small, self-contained component (~500 lines of Go) with a stable interface.
- **Negative:** The glob expansion at startup scales with the number of files in the source directory. For very large repositories, this adds startup latency. Acceptable because agent session startup is dominated by container creation and LLM initialization, not trie construction.
- **Accepted trade-off:** FUSE adds a kernel-to-userspace round-trip per filesystem operation. This is the cost of userspace policy enforcement. The alternative (eBPF) avoids this but at significantly higher development and operational complexity. Since agents are I/O-bound on LLM API calls, filesystem latency is not on the critical path.
