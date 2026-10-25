#!/usr/bin/env bash
# ==============================================================================
# Install git hooks for STAR Mac Listener
# ==============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

mkdir -p "$ROOT_DIR/.git/hooks"
ln -sf "../../scripts/git-hooks/pre-commit" "$ROOT_DIR/.git/hooks/pre-commit"
chmod +x "$ROOT_DIR/scripts/git-hooks/pre-commit"
chmod +x "$ROOT_DIR/.git/hooks/pre-commit"

echo "✅ Git pre-commit hook installed successfully in $ROOT_DIR/.git/hooks/pre-commit"
