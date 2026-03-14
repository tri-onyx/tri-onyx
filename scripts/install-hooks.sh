#!/usr/bin/env bash
# Install git hooks for the TriOnyx project.
# Usage: bash scripts/install-hooks.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
HOOKS_DIR="$REPO_ROOT/.git/hooks"

echo "Installing git hooks..."

# Pre-commit hook
cat > "$HOOKS_DIR/pre-commit" << 'HOOK'
#!/usr/bin/env bash
# TriOnyx pre-commit hook
# Warns if templates are stale and scans for secret leaks.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WARNINGS=0

# 1. Check for accidental secret files being staged
STAGED=$(git diff --cached --name-only)

# Block .env files (except .env.example)
while IFS= read -r file; do
    if [[ "$file" =~ ^\.env ]] && [[ "$file" != ".env.example" ]]; then
        echo "ERROR: Refusing to commit secret file: $file"
        echo "       This file is in .gitignore for a reason."
        exit 1
    fi
done <<< "$STAGED"

# Block secrets/ files (except *.example and .gitkeep)
while IFS= read -r file; do
    if [[ "$file" =~ ^secrets/ ]] && [[ "$file" != *.example ]] && [[ "$file" != */.gitkeep ]] && [[ "$file" != secrets/.gitkeep ]]; then
        echo "ERROR: Refusing to commit secret file: $file"
        echo "       Only .example files and .gitkeep should be committed under secrets/"
        exit 1
    fi
done <<< "$STAGED"

# 2. Scan staged files for embedded secrets
if command -v uv &> /dev/null; then
    if ! uv run "$REPO_ROOT/scripts/generate-templates.py" --scan-secrets 2>/dev/null; then
        echo ""
        echo "WARNING: Possible secrets detected in staged files (see above)."
        echo "         Please review before committing."
        WARNINGS=1
    fi
fi

# 3. Check if templates are stale (warning only)
if command -v uv &> /dev/null; then
    if ! uv run "$REPO_ROOT/scripts/generate-templates.py" --check 2>/dev/null; then
        echo ""
        echo "WARNING: Template files are out of date."
        echo "         Run: uv run scripts/generate-templates.py"
        WARNINGS=1
    fi
fi

if [ "$WARNINGS" -ne 0 ]; then
    echo ""
    echo "Commit proceeding despite warnings. Fix them in a follow-up commit."
fi

exit 0
HOOK

chmod +x "$HOOKS_DIR/pre-commit"
echo "Installed pre-commit hook."

echo "Done. Git hooks installed."
