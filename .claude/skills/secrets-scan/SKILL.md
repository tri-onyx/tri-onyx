---
name: secrets-scan
description: Scan git commits for leaked secrets (API keys, tokens, passwords, private keys, credentials in URLs) before they reach main or a remote. Use this skill whenever the user asks to check commits, a branch, a commit range, or unpushed work for secrets, credentials, keys, or leaks — including phrasings like "review these commits for secrets", "did I commit anything sensitive", "is this branch safe to push", or "audit the diff for credentials". Also use it proactively before pushing a large or unfamiliar range of commits.
---

# Secrets Scan

Scan a range of git commits for committed secrets, then triage the candidates
and report a clear verdict. Automated scanners alone are not enough: gitleaks
catches well-known token formats and high-entropy strings, but misses
contextual secrets (a hardcoded password in a config file, a cookie value, a
dev fallback that ends up running in production). The pattern sweep catches
those candidates, and your triage separates real leaks from noise.

## Step 1 — Determine the range

- If the user gave a range (e.g. `15a38d4..12a0cac`, `origin/main..HEAD`, a
  branch name), use it verbatim.
- Otherwise default to "local commits not yet on main":
  1. `git rev-parse --abbrev-ref @{upstream}` succeeds → use `@{upstream}..HEAD`
  2. else if `origin/main` exists → `origin/main..HEAD`
  3. else if on a branch other than main → `main..HEAD`
  4. else ask the user — there is no unambiguous "unmerged" range.
- Show the user the commit count before scanning so they can catch a wrong
  range early (`git log --oneline <range> | wc -l`). An empty range means
  there is nothing to scan — say so and stop.

## Step 2 — Run the scanner

```bash
bash .claude/skills/secrets-scan/scripts/scan.sh '<range>'
```

The script runs gitleaks over every commit in the range (if installed) and
then a series of pattern sweeps over the added diff lines: keyword
assignments, provider token prefixes, JWTs, URLs with embedded credentials,
private key blocks, high-entropy strings, and newly added sensitive-looking
files. It saves the full diff to `./tmp/secrets-scan/range.diff` for
follow-up greps.

The sweeps are deliberately separate simple greps — `grep` may be ugrep,
which rejects long combined alternations ("exceeds complexity limits"). If
you add follow-up greps, keep each pattern simple too, and write the diff to
a file first rather than re-piping `git diff` every time.

## Step 3 — Triage

Every sweep hit is a candidate, not a finding. Classify each one:

- **Real secret** — a working credential: live API key, password used by
  deployed config, private key material. Scanning the diff line alone is
  often not enough; open the file at that commit (`git show <sha>:<path>`)
  to see context.
- **Dev placeholder** — obviously-fake fallbacks (`dev-insecure-key`,
  `build-placeholder`, `changeme`) read from env with a default. Not a leak,
  but check whether the placeholder is what actually runs (e.g.
  docker-compose never sets the env var) and whether exposure is contained
  (bound to localhost only?). Worth a note, not an alarm.
- **False positive** — CSS classes, variable names, docs prose, test
  fixtures, hashes/digests.

Beyond the sweep hits, inspect commits whose *subject* suggests credentials
even if no pattern fired: new utility/integration scripts (anything talking
to a third-party API), docker-compose or `.env` changes, CI config, and
settings files. `git show <sha> --stat` first, then read the suspicious
files. Secrets in these spots are often syntactically unremarkable
(`client_secret = "..."` in a one-off script) and pattern sweeps can miss
them when filters eat the line.

## Step 4 — Report

Lead with the verdict: "No secrets found in the N commits between X..Y" or
"Found N secrets that need rotation". Then:

- For each **real secret**: the commit, file, what it grants access to, and
  remediation — the secret must be **rotated** (history rewriting alone is
  not enough once pushed). If the range is unpushed, also offer to rewrite
  history (`git rebase -i` / amend) so it never reaches the remote; if
  already pushed, mention `git filter-repo` plus rotation.
- For **dev placeholders / near-misses**: a short "non-secret observations"
  section so the user knows you saw them and why they're acceptable (or
  what would make them a problem, e.g. exposure beyond localhost).
- Briefly state coverage: gitleaks ran (or not) plus which sweep families
  ran, so the user knows what the "clean" verdict is based on.
- If gitleaks was not installed, say so explicitly and recommend installing
  it — the pattern sweep alone is weaker coverage.
