# Security hunter ledger

- 2026-11-12 | FIXED     | sandbox-exec | Bound AgentPort's line buffer so sandbox output can't exhaust gateway memory | lib/tri_onyx/agent_port.ex
- 2026-11-12 | DOWNGRADED| sandbox-exec | entrypoint.sh (root phase) runs `chown tri_onyx /workspace/.playwright-cli` without -h on an agent-writable tree; a committed symlink there would hand tri_onyx ownership of an arbitrary in-container path (e.g. /etc) — needs a root container to prove | runtime/entrypoint.sh
- 2026-11-12 | DOWNGRADED| sandbox-exec | Any in-container process can write to the runner's stdout via /proc/<pid>/fd and forge protocol frames; gateway must keep treating every port frame as agent-controlled (no frame should grant more than the agent's own definition) | lib/tri_onyx/agent_port.ex
