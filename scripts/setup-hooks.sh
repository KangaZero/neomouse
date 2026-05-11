#!/usr/bin/env bash
# Point this repository at .githooks/ for git hooks. Run once after cloning.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

git config core.hooksPath .githooks
chmod +x .githooks/* 2>/dev/null || true

echo "core.hooksPath set to .githooks"
echo "Hooks active: $(ls .githooks)"
