# Security hunter ledger

One line per entry, newest last. Statuses: FIXED (fixed in the PR that added the line), DOWNGRADED (real concern, not provable/fixable in a small change — needs a human), NO-FINDING (area swept, nothing cleared the bar).

- 2026-11-11 | FIXED     | gateway-http | Deny git DWIM spellings of protected push targets (`heads/main`) and treat `@` like HEAD | lib/tri_onyx/github/command_policy.ex
- 2026-11-11 | DOWNGRADED| risk-model   | BCP Cat-2/3 word-count cap splits on ASCII `\s` only, so NBSP/U+3000/U+2009 or `_`/`-`-joined text passes as one "word"; a real fix needs a non-whitespace bandwidth measure (e.g. char cap), not a regex tweak | lib/tri_onyx/bcp/validator.ex
- 2026-11-11 | DOWNGRADED| gateway-http | POST /messages: `:api_key` is never set by config/runtime.exs, so ExternalMessage accepts any non-empty bearer and dispatches at low taint; moot while the rest of the management API is unauthenticated, but it contradicts the "API-key authenticated" taint-matrix row | lib/tri_onyx/triggers/external_message.ex
