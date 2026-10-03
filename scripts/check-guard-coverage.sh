#!/usr/bin/env bash
set -euo pipefail

# Every guard that format-lint runs must have a fixture, or a stated reason why
# it cannot have one.
#
# scripts/check-guards.sh proves that each guard with a fixture can fail. It
# could not see a guard with NO fixture, so three pure-grep guards
# (no-language-defaults.sh, no-new-xctest.sh, check-maintenance-palette.sh) ran
# in format-lint with nothing to show they could ever go red (#1983). A guard
# that stops catching its defect stays green, and so does a guard that never
# caught it.
#
# The rule: each guard that format-lint runs, and each guard that one of those
# runs in turn (check-styles.sh runs several), is named by a fixture in
# scripts/guard-fixtures/ or is listed in EXEMPT below with its reason. An
# EXEMPT entry for a guard that format-lint no longer runs is an error too, so
# the list cannot go stale.
#
# A guard is its path plus its arguments. `generate-js-constants.sh --check` is
# a check; the same script with no arguments rewrites a file.
#
# Only one level of nesting is read: a guard that a guard runs is found, and a
# guard that THAT one runs is not. No guard nests deeper today.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

workflow=".github/workflows/swift-tests.yml"
fixture_dir="scripts/guard-fixtures"

# Guards that cannot have a fixture, and why. One per line: guard|reason.
EXEMPT='scripts/lint.sh|Runs swift-format. The rules belong to the tool, which has its own tests.
scripts/swiftlint.sh|Runs SwiftLint. The rules belong to the tool, which has its own tests.
scripts/check-runner-wasm-size.sh|Reads the vendored wasm. Its filename carries a content hash, so a fixture that names it breaks at each re-vendor.
scripts/deployment-target-tests.sh|A self-test suite. Its cases are its assertions.
scripts/ci-build-retry.sh --self-test|A self-test of the build-retry gate. Its cases are its assertions.'

# The `run: scripts/...` steps of the format-lint job, with their arguments.
lint_steps="$(
  awk '
    /^  [A-Za-z0-9_-]+:[ \t]*$/ { in_job = ($1 == "format-lint:"); next }
    in_job && /^[ \t]+run:[ \t]+scripts\// {
      line = $0
      sub(/^[ \t]+run:[ \t]+/, "", line)
      sub(/[ \t]+$/, "", line)
      print line
    }
  ' "$workflow"
)"

# A parser that matches nothing is indistinguishable from a job with no guards.
if [ -z "$lint_steps" ]; then
  echo "ERROR: found no 'run: scripts/...' steps in the format-lint job of $workflow."
  echo "       This guard is not reading the workflow."
  exit 1
fi

# The guards each step runs in turn: a line that starts with a scripts/ path,
# cut at the first shell operator.
nested=""
while IFS= read -r step; do
  script="${step%% *}"
  [ -f "$script" ] || continue
  nested+="$(
    awk '
      /^[ \t]*scripts\/[A-Za-z0-9_.-]+\.sh/ {
        line = $0
        sub(/^[ \t]+/, "", line)
        sub(/[ \t]*(\|\||&&|;|\||>).*$/, "", line)
        print line
      }
    ' "$script"
  )"$'\n'
done <<<"$lint_steps"

guards="$(printf '%s\n%s\n' "$lint_steps" "$nested" | grep . | awk '!seen[$0]++')"

proven="$(
  for f in "$fixture_dir"/*.fixture; do
    # shellcheck disable=SC1090
    ( guard=""; args=""; source "$f"; printf '%s\n' "$guard${args:+ $args}" )
  done | sort -u
)"

exempt_names="$(printf '%s\n' "$EXEMPT" | cut -d'|' -f1)"

status=0

unproven=""
proven_count=0
exempt_count=0
while IFS= read -r g; do
  if grep -qxF -- "$g" <<<"$proven"; then
    proven_count=$((proven_count + 1))
  elif grep -qxF -- "$g" <<<"$exempt_names"; then
    exempt_count=$((exempt_count + 1))
  else
    unproven+="  ${g}"$'\n'
  fi
done <<<"$guards"

if [ -n "$unproven" ]; then
  status=1
  echo "ERROR: format-lint runs a guard that no fixture proves can fail."
  echo
  printf '%s' "$unproven"
  echo
  echo "Add a fixture in $fixture_dir/ (scripts/check-guards.sh describes the"
  echo "format), or add the guard to EXEMPT in scripts/check-guard-coverage.sh"
  echo "with the reason it cannot have one."
  echo
fi

stale=""
while IFS= read -r e; do
  grep -qxF -- "$e" <<<"$guards" || stale+="  ${e}"$'\n'
done <<<"$exempt_names"

if [ -n "$stale" ]; then
  status=1
  echo "ERROR: EXEMPT names a guard that format-lint no longer runs."
  echo
  printf '%s' "$stale"
  echo
  echo "Delete the entry from EXEMPT in scripts/check-guard-coverage.sh."
  echo
fi

if [ "$status" -eq 0 ]; then
  total="$(grep -c . <<<"$guards")"
  echo "check-guard-coverage: OK (${total} guards: ${proven_count} proven by a fixture, ${exempt_count} exempt)"
fi

exit "$status"
