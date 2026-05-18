#!/usr/bin/env bash
set -euo pipefail

# Fails if any test file outside the allowlist imports XCTest, or if any
# file on the allowlist no longer imports XCTest (i.e. it was migrated and
# the allowlist wasn't trimmed).
#
# Two-way check:
#   - new XCTest imports outside the allowlist  → blocks new XCTest tests.
#   - allowlist entries that no longer import XCTest → keeps the allowlist
#     honest as files migrate, so it shrinks toward empty.
#
# When the migration is complete, delete scripts/xctest-allowlist.txt and
# this script will require no `import XCTest` anywhere under Tests/.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

allowlist="scripts/xctest-allowlist.txt"

actual=$(grep -rl "^import XCTest" Tests/ 2>/dev/null | sort || true)

if [ -f "$allowlist" ]; then
  expected=$(sort "$allowlist")
else
  expected=""
fi

# Files importing XCTest that are NOT on the allowlist.
new_xctest=$(comm -23 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") | grep -v '^$' || true)

# Files on the allowlist that no longer import XCTest (migrated).
stale_allowlist=$(comm -13 <(printf '%s\n' "$actual") <(printf '%s\n' "$expected") | grep -v '^$' || true)

status=0

if [ -n "$new_xctest" ]; then
  echo "ERROR: New file(s) import XCTest. Use Swift Testing for new tests:"
  echo "$new_xctest" | sed 's/^/  /'
  echo
  echo "If this is intentional (e.g. unblocking a fix), add the path to"
  echo "$allowlist and justify in the PR description."
  status=1
fi

if [ -n "$stale_allowlist" ]; then
  echo "ERROR: Allowlist entries no longer import XCTest (migrated). Remove them from $allowlist:"
  echo "$stale_allowlist" | sed 's/^/  /'
  status=1
fi

if [ $status -eq 0 ]; then
  count=$(printf '%s\n' "$actual" | grep -c . || true)
  echo "no-new-xctest: OK ($count file(s) on allowlist; $(grep -rl '^import Testing' Tests/ 2>/dev/null | wc -l | tr -d ' ') file(s) on Swift Testing)"
fi

exit $status
