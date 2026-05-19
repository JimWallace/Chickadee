#!/usr/bin/env bash
set -euo pipefail

# Migration complete: every test file is on Swift Testing.  This guard
# now simply asserts that no file under `Tests/` imports XCTest.
#
# If you ever genuinely need XCTest (e.g. measure blocks not yet
# available in Swift Testing), discuss in CLAUDE.md before adding.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

actual=$(grep -rl "^import XCTest" Tests/ 2>/dev/null | sort || true)

if [ -n "$actual" ]; then
  echo "ERROR: New file(s) import XCTest. Use Swift Testing for new tests:"
  echo "$actual" | sed 's/^/  /'
  exit 1
fi

count=$(grep -rl "^import Testing" Tests/ 2>/dev/null | wc -l | tr -d ' ')
echo "no-new-xctest: OK ($count file(s) on Swift Testing; 0 on XCTest)"
