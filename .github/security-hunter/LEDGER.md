# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-24 | FIXED | sandbox-exec | Reject plugin names that escape the plugins/ directory via `..` segments | lib/tri_onyx/agent_definition.ex
- 2026-09-24 | NO-FINDING | sandbox-exec | Reviewed lib/tri_onyx/sandbox.ex mount_plan/repo_mount_flags/env_flags, lib/tri_onyx/system_command.ex, lib/tri_onyx/agent_port.ex, lib/tri_onyx/tool_registry.ex, runtime/protocol.py, runtime/entrypoint.sh (network policy / plugin dep install / privilege drop). The `/restart` system-command trust/authorization bypass in connector_handler.ex + system_command.ex is real but already covered by open PRs #37 and #53 — not re-reported. iptables `allow_host` in entrypoint.sh passes attacker-influenced host/port through quoted shell variables into `iptables -d`, no injection found (properly quoted, no eval). `docker_socket_flags`/`trionyx_repo_flags` gate on agent-definition booleans set by whoever controls the definition, not runtime attacker input — no escalation found from inside the sandbox itself.
