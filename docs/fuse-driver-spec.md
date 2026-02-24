# TriOnyx FUSE Driver — Agent Build Prompt

You are building `tri-onyx-fs`, a FUSE filesystem driver for the TriOnyx agent sandboxing system. This driver enforces fine-grained file access control inside Docker containers where AI agents run.

## Context

TriOnyx is an autonomous AI agent framework. Each agent runs in its own Docker container with **zero filesystem access by default**. The gateway spawns the container and mounts this FUSE filesystem as the agent's only view of the host. The FUSE driver receives an allowlist of glob patterns (split into read and write) and denies everything else.

This is a **security boundary**. Every `open()`, `stat()`, `readdir()`, `write()` the agent process makes goes through this driver. Correctness matters more than features.

## Architecture

```
┌─────────────────────────────────────┐
│         Docker Container            │
│                                     │
│   Agent Process (Python/Claude SDK) │
│         │                           │
│         │  syscalls (open, read...) │
│         ▼                           │
│   /workspace  (FUSE mount)          │
│         │                           │
│   tri-onyx-fs (this driver)       │
│         │                           │
│         │  allowed? ──▶ passthrough │
│         │  denied?  ──▶ EACCES     │
│         ▼                           │
│   /mnt/host  (bind mount from host) │
└─────────────────────────────────────┘
```

The driver is a **passthrough filesystem with an access control overlay**. It mirrors a source directory (the bind-mounted host path) but filters every operation against the configured glob patterns.

## Language and Dependencies

- **Language:** Go
- **FUSE library:** `github.com/hanwen/go-fuse/v2` (use the `fs` package / v2 API — actively maintained, used by Google)
- **Glob matching:** `github.com/bmatcuk/doublestar/v4` (required for `**` support; Go's `filepath.Match` does not support `**`)
- **No other external dependencies.** Keep the binary self-contained.

## Configuration

The driver receives its configuration as a JSON file passed via CLI argument:

```
tri-onyx-fs --config /etc/tri_onyx/fs-policy.json --source /mnt/host --mountpoint /workspace
```

**Policy file format:**

```json
{
  "fs_read": [
    "/repo/**/*.py",
    "/repo/**/*.md",
    "/repo/pyproject.toml"
  ],
  "fs_write": [
    "/repo/src/output/**"
  ],
  "log_denials": true
}
```

- All glob patterns are relative to the mountpoint root (which maps to the source directory).
- `fs_write` implies `fs_read` for the same paths — if you can write, you can read.
- Empty arrays mean no access. Missing keys mean empty arrays.
- `fs_read: ["**"]` grants full read access (use sparingly).

## Operations to Intercept

Implement a passthrough FUSE filesystem that intercepts and checks **every** operation. The `go-fuse` v2 `fs` package uses a node-based API. Implement at minimum:

### Read operations (checked against `fs_read` + `fs_write`):
- `Lookup` — resolve child names (needed for path traversal)
- `Getattr` — stat a file/directory
- `Opendir` / `Readdir` — list directory contents
- `Open` — open a file for reading
- `Read` — read file contents

### Write operations (checked against `fs_write` only):
- `Create` — create a new file
- `Mkdir` — create a directory
- `Write` — write to a file
- `Setattr` — change permissions/timestamps
- `Rename` — move/rename (check both source and destination)
- `Unlink` — delete a file
- `Rmdir` — delete a directory
- `Symlink` — unconditionally denied with EPERM (symlinks bypass path-based access control)
- `Link` — create hard links (check the target path)

### Access check logic:

```
func isAllowed(path string, patterns []string) bool:
    for each pattern in patterns:
        if doublestar.Match(pattern, path):
            return true
    return false

func checkRead(path string) bool:
    return isAllowed(path, policy.fs_read) || isAllowed(path, policy.fs_write)

func checkWrite(path string) bool:
    return isAllowed(path, policy.fs_write)
```

### Directory traversal

Directories along the path to an allowed file must be traversable (Lookup and Getattr succeed) even if not explicitly in the glob pattern. For example, if `fs_read` contains `/repo/src/**/*.py`, then `/`, `/repo`, and `/repo/src` must be traversable. However, `Readdir` on those intermediate directories should only show entries that lead to allowed paths (information hiding).

This is the hardest part of the implementation. The naive approach is to allow Lookup/Getattr on all directories but filter Readdir results. A more secure approach pre-computes the set of visible directory entries from the glob patterns at startup.

**Recommended approach:** At startup, expand all glob patterns against the source directory to build a trie of allowed paths. Use the trie for O(1) lookup and filtered readdir. Re-scan periodically or on inotify events if the source changes (but this is a future enhancement — static scan at startup is fine for v1).

## Denial Behavior

- Denied operations return `syscall.EACCES` (permission denied).
- If `log_denials` is true, log each denial to stderr as structured JSON:

```json
{"event":"denied","op":"open","path":"/repo/.env","mode":"read","time":"2026-02-13T12:00:00Z"}
```

The gateway captures the container's stderr and can route denial logs to the audit system.

## Performance Considerations

- **Cache aggressively.** Use `go-fuse`'s built-in kernel caching (`EntryTimeout`, `AttrTimeout`). Set reasonable TTLs (e.g., 1 second for dev, longer for production).
- **Pre-compute glob matches** at startup into a path trie rather than evaluating globs per syscall. The policy is static for the lifetime of the mount.
- **Minimize allocations** in the hot path (Lookup, Getattr, Read). These are called constantly.
- The driver should add negligible overhead for allowed operations — essentially native passthrough speed with a map lookup.

## Build and Output

- The module should live at `fuse/` in the TriOnyx repo root.
- Go module name: `github.com/TriOnyx/tri-onyx-fs`
- Build target: `go build -o tri-onyx-fs ./cmd/tri-onyx-fs`
- The output is a single static binary.

**Directory structure:**

```
fuse/
├── cmd/
│   └── tri-onyx-fs/
│       └── main.go            # CLI entry point, arg parsing, mount
├── internal/
│   ├── policy/
│   │   ├── policy.go          # Parse JSON policy, expand globs to trie
│   │   └── policy_test.go
│   ├── pathtrie/
│   │   ├── trie.go            # Path trie for O(1) access checks
│   │   └── trie_test.go
│   └── fs/
│       ├── trionyxfs.go    # FUSE node implementation (passthrough + checks)
│       └── trionyxfs_test.go
├── go.mod
├── go.sum
└── README.md
```

## Testing

Write unit tests for:

1. **Policy parsing** — valid JSON, missing fields default to empty, malformed JSON errors
2. **Glob matching** — standard globs, `**` patterns, edge cases (dotfiles, symlinks, root)
3. **Path trie** — build from patterns, check read/write, directory traversal visibility
4. **Denial logging** — structured JSON output on stderr

Integration tests (can be a separate test binary or shell script):

1. Mount the FUSE filesystem with a test policy
2. Verify allowed reads succeed
3. Verify denied reads return EACCES
4. Verify allowed writes succeed
5. Verify denied writes return EACCES
6. Verify readdir filters hidden entries
7. Verify directory traversal to allowed deep paths works

## Constraints

- **No runtime dependencies.** The binary must run inside a minimal container.
- **Linux only.** FUSE on Linux. No macOS/Windows support needed.
- **No network access.** The driver never makes network calls.
- **Fail closed.** If policy parsing fails or any unexpected error occurs, deny all access. Never fail open.
- **No dynamic policy updates in v1.** Policy is read once at startup. Remounting is how you change policy.
- **Signal handling.** Clean unmount on SIGTERM and SIGINT (the gateway sends SIGTERM when stopping a container).

## Non-Goals (explicitly out of scope)

- SELinux/AppArmor integration (the FUSE layer is the enforcement mechanism)
- Encryption at rest
- Network filesystem support
- User/group-based access control (all access is controlled by the policy, not Unix permissions)
- inotify-based policy reloading (future enhancement)
