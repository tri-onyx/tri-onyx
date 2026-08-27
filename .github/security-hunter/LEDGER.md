# Security Hunter Ledger

One line per entry, newest last.

- 2026-08-27 | FIXED | sandbox-exec | Deny scp-style `host:path` git remotes (no `user@` needed) that let a sandboxed agent make the gateway open an arbitrary/internal ssh connection via the GitHub tool | lib/tri_onyx/github/command_policy.ex
