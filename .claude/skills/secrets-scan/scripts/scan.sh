#!/usr/bin/env bash
# Scan a git commit range for secrets: gitleaks (if installed) plus
# supplementary pattern sweeps over added diff lines.
#
# Usage: scan.sh <git-range>      e.g. scan.sh origin/main..HEAD
#
# Output is a candidate list, NOT a verdict — every hit needs triage by the
# caller (real secret vs dev placeholder vs false positive).
set -u

RANGE="${1:?usage: scan.sh <git-range>}"
OUT_DIR="./tmp/secrets-scan"
mkdir -p "$OUT_DIR"
DIFF="$OUT_DIR/range.diff"

git diff "$RANGE" > "$DIFF" || { echo "git diff failed for range: $RANGE" >&2; exit 1; }

echo "## Commits in range ($RANGE)"
git log --oneline "$RANGE"
echo

echo "## gitleaks"
if command -v gitleaks >/dev/null 2>&1; then
  gitleaks git --log-opts="$RANGE" --no-banner --report-format json \
    --report-path "$OUT_DIR/gitleaks-report.json" -v 2>&1 | tail -10
  echo "(full report: $OUT_DIR/gitleaks-report.json)"
else
  echo "gitleaks not installed — skipped. Pattern sweep below still runs,"
  echo "but recommend installing gitleaks for rule/entropy coverage."
fi
echo

# Each sweep is a separate, simple grep on purpose: grep is aliased to ugrep
# on some machines, and ugrep rejects long combined alternations with
# "exceeds complexity limits". Do not merge these into one regex.
sweep() {
  local label="$1" pattern="$2" filter="${3:-}"
  echo "### $label"
  if [ -n "$filter" ]; then
    grep -inE "$pattern" "$DIFF" | grep -viE "$filter" | head -40
  else
    grep -inE "$pattern" "$DIFF" | head -40
  fi
  echo
}

echo "## Pattern sweep (added lines; expect false positives — triage required)"

# Env-var reads stay in: a read with a hardcoded fallback default
# (e.g. os.environ.get("KEY", "dev-insecure-...")) is a triage-worthy hit.
sweep "Keyword assignments (password/secret/token/key)" \
  '^\+.*[._A-Za-z-]*(password|passwd|secret|token|api_?key|credential)[._A-Za-z-]*\s*[:=]' \
  'csrf|risk|test|spec|example|your[_-]|dummy|fake|mock|\{\{|\$\{'

sweep "Provider token prefixes (cloud/CI)" \
  '^\+.*(AKIA[0-9A-Z]{16}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_|glpat-)'

sweep "Provider token prefixes (AI/chat)" \
  '^\+.*(sk-ant-|sk-proj-|xox[bap]-|syt_[A-Za-z0-9]+|hf_[A-Za-z0-9]{30,}|AIza[0-9A-Za-z_-]{30})'

sweep "JWTs" \
  '^\+.*eyJ[A-Za-z0-9_-]{20,}'

sweep "URLs with embedded credentials" \
  '^\+.*://[^/ :]+:[^@ ]+@'

sweep "Private key blocks" \
  '^\+.*BEGIN [A-Z ]*PRIVATE KEY|^\+.*BEGIN (RSA|EC|OPENSSH|PGP|DSA)'

sweep "High-entropy strings (48+ base64-ish chars)" \
  '^\+[^+].*[A-Za-z0-9+/=_-]{48,}' \
  'href|src=|url\(|path|class=|font|data:|\.css|\.js|woff|svg|test|spec|hash|digest|sha256|integrity|uuid|lock'

echo "### Newly added sensitive-looking files"
git diff "$RANGE" --name-only --diff-filter=A \
  | grep -iE '\.(env|pem|key|p12|pfx|crt|keystore|jks)$|secret|credential|token' \
  | head -20
echo

echo "Diff saved to $DIFF for follow-up greps."
