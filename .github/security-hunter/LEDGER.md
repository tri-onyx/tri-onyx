# Security Hunter Ledger

One line per entry, newest last.

- 2026-09-14 | FIXED | risk-model | Runtime taint classification never used Bash's network-aware context — a network-enabled agent's Bash tool results always classified `:low` taint regardless of network policy, unlike Read's controlled/external split, letting curl/wget-sourced external data skip taint escalation and kill-on-threshold enforcement | lib/tri_onyx/information_classifier.ex
