#!/usr/bin/env bash
set -euo pipefail

# ESLint gate for first-party frontend JavaScript (#1134).
#
# Scope and rules live in eslint.config.mjs at the repo root: Public/*.js
# (classic scripts + the two ES-module renderers) and the
# Tests/BrowserRunnerJSTests node suite.  Vendored/generated trees
# (Public/pyodide, Public/jupyterlite, Public/vendor) are never linted.
#
# Zero tolerance, matching scripts/swiftlint.sh: --max-warnings 0 means any
# finding — error or warning, including an unused eslint-disable directive —
# fails the build.  Fix the finding or carry an explicit disable comment
# with a reason.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ ! -x node_modules/.bin/eslint ]; then
  echo "eslint not installed; running npm ci ..."
  npm ci --no-audit --no-fund
fi

node_modules/.bin/eslint --max-warnings 0 Public/*.js Tests/BrowserRunnerJSTests/*.mjs
echo "eslint: OK (Public/*.js + Tests/BrowserRunnerJSTests clean)"
