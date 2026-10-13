#!/usr/bin/env bash
set -uo pipefail

# Runs every step of the CI `format-lint` job on this machine, and reports
# which steps fail.
#
# The list of steps is not copied here. The script reads it from the
# `format-lint` job in .github/workflows/swift-tests.yml, so a step added to
# CI runs here too, with no edit. The `lint-guard` agent and the Claude Code
# pre-push hook (.claude/hooks/pre-push-format-lint.py) both run this script.
#
# Usage:
#   scripts/format-lint.sh          run every step, print a summary
#   scripts/format-lint.sh --list   print the steps and run none
#
# Exit status: 0 when every step passes, 1 when a step fails, 2 when the job
# cannot be read from the workflow.
#
# Each step reads only source. None of them rewrites a file. The script does
# not run scripts/check-guards.sh, which is not a format-lint step.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root" || exit 2

workflow=".github/workflows/swift-tests.yml"

# Prints one command per line: each `run:` value in the format-lint job that
# starts with `scripts/`. A step that does not is CI plumbing (a cache key),
# not a check. The job ends at the next line that opens another job (two
# spaces, a name, a colon). A `run: |` block has its command on later lines,
# which this reader does not parse, so it prints a marker that makes the
# script stop.
read_steps() {
  awk '
    /^  format-lint:[[:space:]]*$/ { in_job = 1; next }
    in_job && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { exit }
    in_job && /^[[:space:]]+run:[[:space:]]*/ {
      sub(/^[[:space:]]+run:[[:space:]]*/, "")
      if ($0 == "|" || $0 == ">" || $0 == "") { print "MULTILINE-RUN-STEP"; next }
      if ($0 ~ /^scripts\//) print
    }
  ' "$workflow"
}

steps="$(read_steps)"
if [ -z "$steps" ]; then
  echo "format-lint.sh: found no format-lint steps in $workflow" >&2
  exit 2
fi
if printf '%s\n' "$steps" | grep -qx 'MULTILINE-RUN-STEP'; then
  echo "format-lint.sh: the format-lint job has a multi-line run step." >&2
  echo "This script reads only one-line steps. Make the step one line, or" >&2
  echo "move its body into a script." >&2
  exit 2
fi

if [ "${1:-}" = "--list" ]; then
  printf '%s\n' "$steps"
  exit 0
fi

failed=()
count=0
while IFS= read -r step; do
  count=$((count + 1))
  echo "==> $step"
  if ! bash -c "$step" </dev/null; then
    failed+=("$step")
  fi
done <<<"$steps"

echo
if [ "${#failed[@]}" -eq 0 ]; then
  echo "format-lint passes ($count steps)."
  exit 0
fi
echo "format-lint fails: ${#failed[@]} of $count steps."
for step in "${failed[@]}"; do
  echo "  FAILED: $step"
done
exit 1
