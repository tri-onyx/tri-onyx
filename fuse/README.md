# tri-onyx-fs

FUSE filesystem driver for TriOnyx agent sandboxing. Mounts a passthrough filesystem that filters every syscall against a JSON policy of glob patterns.

## How it works

```
Agent Process (in container)
        │
        │  syscalls (open, read, write...)
        ▼
  /workspace  (FUSE mount)
        │
  tri-onyx-fs (this driver)
        │
        ├── allowed? → passthrough to source
        └── denied?  → EACCES
        ▼
  /mnt/host  (bind mount from host)
```

The driver reads a policy file at startup, expands all glob patterns against the source directory into a path trie, and uses O(1) lookups to check every filesystem operation. Policy is static for the lifetime of the mount.

## Usage

```
tri-onyx-fs --config /etc/tri_onyx/fs-policy.json \
              --source /mnt/host \
              --mountpoint /workspace
```

## Policy format

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

- `fs_read`: glob patterns for read-only access
- `fs_write`: glob patterns for read+write access (write implies read)
- `log_denials`: emit structured JSON to stderr on denied operations
- All patterns are relative to the mountpoint root
- Missing keys default to empty arrays / false

## Building

```
cd fuse
go build -o tri-onyx-fs ./cmd/tri-onyx-fs
```

## Testing

```
go test ./internal/pathtrie/...   # trie unit tests
go test ./internal/policy/...     # policy unit tests
go test ./internal/fs/...         # FUSE integration tests (requires /dev/fuse)
```

## Architecture

| Package | Purpose |
|---------|---------|
| `internal/pathtrie` | Path trie for O(1) access checks and filtered readdir |
| `internal/policy` | JSON parsing and glob expansion via doublestar |
| `internal/fs` | go-fuse v2 node implementation with access control overlay |
| `cmd/tri-onyx-fs` | CLI entry point, signal handling, structured logging |

## Denial logging

When `log_denials` is true, denied operations are logged to stderr as JSON:

```json
{"event":"denied","op":"open","path":"/repo/.env","mode":"read","time":"2026-02-13T12:00:00Z"}
```

## Dependencies

- [go-fuse/v2](https://github.com/hanwen/go-fuse) — FUSE library (v2 node API)
- [doublestar/v4](https://github.com/bmatcuk/doublestar) — `**` glob support
