#!/usr/bin/env bash
set -euo pipefail

# Every guard that CI runs must have a fixture, or a stated reason why it cannot
# have one.
#
# scripts/check-guards.sh proves that each guard with a fixture can fail. It
# could not see a guard with NO fixture, so three pure-grep guards
# (no-language-defaults.sh, no-new-xctest.sh, check-maintenance-palette.sh) ran
# in format-lint with nothing to show they could ever go red (#1983). A guard
# that stops catching its defect stays green, and so does a guard that never
# caught it.
#
# The rule: each script that a workflow or composite action runs, and each guard
# that one of those runs in turn (check-styles.sh runs several), is named by a
# fixture in scripts/guard-fixtures/ or is listed in EXEMPT below with its
# reason. An EXEMPT entry for a script that CI no longer runs is an error too,
# so the list cannot go stale.
#
# This read only the format-lint job until #2428. The JupyterLite guards, one of
# which went silently partial for five releases, ran in other workflows with no
# fixture, and nothing here could see them.
#
# A guard is its path plus its leading `--flag` arguments, because a flag
# selects what the script does: `generate-js-constants.sh --check` is a check,
# and the same script with no flag rewrites a file. Other arguments are inputs,
# such as the directory `verify-jupyterlite.sh` reads, and are not part of the
# name.
#
# Only one level of nesting is read: a guard that a guard runs is found, and a
# guard that THAT one runs is not. No guard nests deeper today.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

fixture_dir="scripts/guard-fixtures"

# Guards that cannot have a fixture, and why. One per line: guard|reason.
EXEMPT='scripts/lint.sh|Runs swift-format. The rules belong to the tool, which has its own tests.
scripts/swiftlint.sh|Runs SwiftLint. The rules belong to the tool, which has its own tests.
scripts/check-runner-wasm-size.sh|Reads the vendored wasm. Its filename carries a content hash, so a fixture that names it breaks at each re-vendor.
scripts/deployment-target-tests.sh|A self-test suite. Its cases are its assertions.
scripts/ci-build-retry.sh --self-test|A self-test of the build-retry gate. Its cases are its assertions.
scripts/check-guards.sh|The fixture runner. The fixtures are its cases, and it fails on an empty set.
scripts/ci-build-retry.sh|Not a check. It runs the build and retries a known compiler crash.
scripts/eslint.sh|Runs ESLint. The rules belong to the tool, which has its own tests.
scripts/test-chickadee-deployer.sh|A behaviour test suite. Its cases are its assertions.
scripts/test-chickadee-runner-update.sh|A behaviour test suite. Its cases are its assertions.
scripts/test-snapshot-retention.sh|A behaviour test suite. Its cases are its assertions.
scripts/check-kernel-currency.py --self-test|A self-test of the currency check. Its cases are its assertions.
scripts/check-kernel-currency.py|Asks the emscripten-forge channel for newer kernels, so its answer depends on the network. A scheduled report, not a gate.
scripts/check-security-headers.sh|Reads the headers of a running server, which the ZAP job starts. A fixture has no server to break.
scripts/ci-compose-env.sh|Not a check without --check. It writes the .env that the ZAP job starts compose with.
scripts/mutation-run.sh|Not a check. It runs the weekly mutation report.
scripts/setup-jupyterlite.sh|Not a check. It installs the JupyterLite build tools.
scripts/build-jupyterlite.sh|Not a check. It builds the vendored bundle.
scripts/build-runner-wasm.sh|Not a check. It builds the vendored runner wasm.
scripts/runnercore-source-hash.sh|Not a check. It prints the source hash that the runner wasm vendor records.'

# Reduces a command line to a guard name: the script path plus its leading
# `--flag` arguments. It stops at the first other word, which also drops a
# redirect, a pipe or a line continuation.
guard_name() {
  awk '{
    name = $1
    for (i = 2; i <= NF && $i ~ /^--[A-Za-z0-9-]+$/; i++) name = name " " $i
    print name
  }'
}

# Every scripts/ command in a workflow or composite action: a `run:` line, or a
# line of a multi-line `run: |` block. A path filter (`- "scripts/..."`) or a
# comment does not start with the path, so it does not match.
ci_steps="$(
  awk '
    /^[ \t]+(run:[ \t]+)?(\.\/)?scripts\/[A-Za-z0-9_.-]+\.(sh|py)([ \t]|$)/ {
      line = $0
      sub(/^[ \t]+(run:[ \t]+)?(\.\/)?/, "", line)
      print line
    }
  ' .github/workflows/*.yml .github/actions/*/action.yml | guard_name | awk '!seen[$0]++'
)"

# A parser that matches nothing is indistinguishable from CI with no guards.
if ! grep -qx 'scripts/check-styles.sh' <<<"$ci_steps"; then
  echo "ERROR: found no 'scripts/check-styles.sh' step in .github/workflows/."
  echo "       This guard is not reading the workflows."
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
done <<<"$ci_steps"

guards="$(printf '%s\n%s\n' "$ci_steps" "$nested" | grep . | guard_name | awk '!seen[$0]++')"

proven="$(
  for f in "$fixture_dir"/*.fixture; do
    # shellcheck disable=SC1090
    ( guard=""; args=""; source "$f"; printf '%s\n' "$guard${args:+ $args}" )
  done | guard_name | sort -u
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
  echo "ERROR: CI runs a guard that no fixture proves can fail."
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
  echo "ERROR: EXEMPT names a guard that CI no longer runs."
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
