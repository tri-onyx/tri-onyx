# Secret Management

TriOnyx uses environment variables and config files for secrets. This page documents where secrets live, how they're protected from accidental leaks, and how to manage them safely.

---

## Where secrets live

| Location | Contents | Tracked in git? |
|---|---|---|
| `.env` | API tokens, passwords, shared secrets | No (gitignored) |
| `secrets/connector-config.yaml` | Chat adapter tokens, room mappings | No (gitignored) |
| `.env.example` | Redacted template with empty values | Yes |
| `secrets/connector-config.yaml.example` | Redacted template with placeholders | Yes |

Both `.env` and `secrets/` are in `.gitignore`. Only `.example` files and `.gitkeep` are committed.

---

## Leak prevention

Secrets are protected by three layers in the pre-commit hook:

### 1. Path blocking

The hook refuses to commit files that should never be tracked:

- `.env` files (except `.env.example`)
- Files under `secrets/` (except `.example` and `.gitkeep`)

This is a hard block — the commit fails immediately.

### 2. gitleaks

[gitleaks](https://github.com/gitleaks/gitleaks) scans all staged file content against 100+ rules for known secret formats:

- API key prefixes (`xoxb-`, `ghp_`, `AKIA`, `sk-live-`, etc.)
- Private keys and certificates
- Connection strings with embedded credentials
- High-entropy strings matching token patterns

This is a hard block. If gitleaks finds a match, the commit fails with the file and line number.

The project config (`.gitleaks.toml`) extends the default ruleset and allowlists `.example` files and design docs that contain placeholder values.

### 3. Custom regex scan

A supplementary scanner (`scripts/generate-templates.py --scan-secrets`) checks for:

- Values matching known API key prefixes (`sk`, `xoxb`, `ghp`, `glpat`, etc.)
- Long base64-like strings (40+ characters)
- URLs with embedded credentials (`https://user:pass@host`)

This runs as a warning — the commit proceeds but flags suspicious content.

---

## Setup

### Install hooks

```bash
bash scripts/install-hooks.sh
```

### Install gitleaks

```bash
brew install gitleaks
```

If gitleaks is not installed, the hook prints a warning and falls back to the regex scanner only.

### Verify

Test that the hook catches secrets:

```bash
echo 'TOKEN=xoxb-fake-token-value-here' > test.txt
git add test.txt
git commit -m "test"   # should fail
git reset HEAD test.txt && rm test.txt
```

---

## Template generation

When you add or change secrets in `.env` or `secrets/connector-config.yaml`, regenerate the example templates:

```bash
uv run scripts/generate-templates.py
```

The generator reads your live config files and produces redacted copies:

- Secret-bearing keys (matching `token`, `password`, `secret`, `key`, etc.) have their values stripped
- Matrix IDs are replaced with placeholders
- High-entropy values are removed regardless of key name
- Comments with embedded secrets are also redacted

The pre-commit hook warns if templates are stale.

---

## Allowlisting false positives

If gitleaks flags a legitimate value (e.g., a placeholder in documentation), add an allowlist entry to `.gitleaks.toml`:

```toml
[allowlist]
  paths = [
    '''docs/my-doc-with-examples\.md''',
  ]
```

You can also allowlist by rule ID, commit hash, or regex. See the [gitleaks docs](https://github.com/gitleaks/gitleaks#configuration).

---

## Rotating secrets

1. Update the values in `.env` and/or `secrets/connector-config.yaml`
2. Restart affected services: `docker compose restart`
3. Regenerate templates: `uv run scripts/generate-templates.py`

No rebuild is needed — secrets are passed as environment variables or bind-mounted config files.
