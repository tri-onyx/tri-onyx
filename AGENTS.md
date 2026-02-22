# TriOnyx Agent Instructions

> **Note:** `CLAUDE.md` is a symlink to this file (`AGENTS.md`). Edit `AGENTS.md` directly.

## Development Workflow

When building new features, follow these steps in order:

1. **Clarify requirements** — Use `AskUserQuestion` to confirm scope, approach, and any ambiguous details before writing code. Don't start implementing until the plan is agreed on.

2. **Build the feature** — Make code changes. Rebuild any affected images before moving on (see Container Rebuilds below).

3. **Run existing tests** — Always run the relevant test suite after making changes:
   - Elixir (gateway): `docker run --rm -v $(pwd):/app -w /app tri-onyx-gateway:latest mix test`
   - Go (FUSE): `docker run --rm --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined -v $(pwd)/fuse:/src -w /src golang:1.22 bash -c "apt-get update -qq && apt-get install -y -qq fuse3 2>/dev/null && go test ./..."`
   - Python (connector): `docker run --rm -v $(pwd)/connector:/app -w /app connector:latest uv run pytest`

4. **Rebuild images and restart containers** — Before running end-to-end tests, rebuild any affected images and restart containers so the latest code is running (see Container Rebuilds below).

5. **Run end-to-end tests** — If the feature touches the agent runtime, connector, or gateway communication, run a live end-to-end test using the test-agent harness:
   ```
   uv run scripts/test-agent.py --agent <agent-name> --prompt "<test prompt>"
   ```
   Check that tool calls, results, and Matrix output all look correct.

## Testing

- **Always run tests inside Docker containers** — never run mix, go, or python tests directly on the host
- Elixir tests: `docker run --rm -v $(pwd):/app -w /app tri-onyx-gateway:latest mix test`
- Go FUSE tests: `docker run --rm --device /dev/fuse --cap-add SYS_ADMIN --security-opt apparmor=unconfined -v $(pwd)/fuse:/src -w /src golang:1.22 bash -c "apt-get update -qq && apt-get install -y -qq fuse3 2>/dev/null && go test ./..."`
  - The `golang:1.22` image lacks `fusermount`, so `fuse3` must be installed for the `internal/fs` integration tests. The `pathtrie` and `policy` tests run without it.

## FUSE Driver (`fuse/`)

The FUSE driver (`tri-onyx-fs`) enforces per-agent filesystem access control inside agent containers. Key things to know:

- **The Dockerfile copies a pre-built binary** — `agent.Dockerfile` does `COPY fuse/tri-onyx-fs` (line 37). It does NOT compile from source. After changing Go code, you must recompile the binary before rebuilding the image:
  ```
  docker run --rm -v $(pwd)/fuse:/src -w /src golang:1.22 go build -o tri-onyx-fs ./cmd/tri-onyx-fs
  docker build --no-cache -t tri-onyx-agent:latest -f agent.Dockerfile .
  ```
- **The path trie is static, write globs are dynamic** — `policy.Expand()` walks the host directory at mount time and builds a trie of existing files. New files (that don't exist yet) are authorized by `checkWriteDynamic()` which matches against raw write glob patterns. Both `Opendir` and `Readdir` must fall back to `checkWriteDynamic` for directories that are writable but empty at mount time.
- **Every agent gets `/agents/{name}/**` as a default write path** — injected by `Sandbox.build_fuse_policy/1` in Elixir. This is how agents write to their memory files without needing explicit `fs_write` entries.
- **Symlinks are unconditionally denied** — they bypass path-based access control since the target is opaque.

## Container Rebuilds

- **Always rebuild containers after making changes** that affect baked-in artifacts
- The agent image (`tri-onyx-agent`) bakes in the FUSE binary and Python runtime — rebuild with `--no-cache` after changing Go or Python source. **Remember to recompile the FUSE binary first** (see FUSE Driver section above):
  `docker build --no-cache -t tri-onyx-agent:latest -f agent.Dockerfile .`
- The gateway image (`tri-onyx-gateway`) mounts Elixir source at runtime, so it only needs rebuilding if `gateway.Dockerfile` itself changes:
  `docker build -t tri-onyx-gateway:latest -f gateway.Dockerfile .`
- After rebuilding, restart any running containers to pick up the new image

## Screenshot Tool

- Use `uv run scripts/screenshot.py <url-or-file>` to render a page and save a screenshot
- Accepts local file paths (e.g. `./webgui/index.html`) or URLs (e.g. `http://localhost:8080`)
- Options: `-o output.png` for output path, `-W 1920 -H 1080` for viewport size
- Dependencies are managed inline via PEP 723 — no manual install needed

## Temporary Files

- Always use local tmp directories within the project (e.g., `./tmp/`) instead of system-wide `/tmp/`
- Create temporary test directories under the project root for isolation and cleanup
- Example: `mkdir -p ./tmp/test-data` instead of `/tmp/test-data`
