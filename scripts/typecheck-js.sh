#!/usr/bin/env bash
set -euo pipefail

# Type-checks first-party frontend JavaScript with tsc (#2782).
#
# Scope lives in jsconfig.json: Public/*.js plus the global declarations in
# types/. checkJs is off there, so tsc checks each file that opts in with a
# `// @ts-check` first line. scripts/check-ts-check-optin.sh makes sure every
# file opts in except the ones in scripts/ts-check-pending.txt.
#
# There is no build step. tsc runs with noEmit, and Public/*.js is still
# served as-is. Types live in JSDoc comments only.
#
# Zero tolerance, like scripts/eslint.sh: any error fails.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ ! -x node_modules/.bin/tsc ]; then
  echo "typescript not installed; running npm ci ..."
  npm ci --no-audit --no-fund
fi

node_modules/.bin/tsc -p jsconfig.json
echo "tsc: OK (Public/*.js files with // @ts-check are clean)"
