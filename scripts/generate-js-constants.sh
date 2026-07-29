#!/usr/bin/env bash
#
# Generate JS constants in Public/browser-runner.js from their canonical Swift
# declarations, so the browser copy is machine-written instead of hand-synced.
#
# Today one constant is generated: R_KERNEL_NAMES, from
# AssignmentLanguage.rKernelNames (Sources/Core/AssignmentLanguage.swift). The
# browser cannot import Swift, so it needs a copy; this script owns that copy.
# The block in browser-runner.js is fenced:
#
#   // CHICKADEE_GENERATED:R_KERNEL_NAMES:BEGIN
#   const R_KERNEL_NAMES = ['ir', 'r', 'webr', 'xr'];
#   // CHICKADEE_GENERATED:R_KERNEL_NAMES:END
#
# Generate-and-diff replaces the retired regex-parse drift test
# (Tests/BrowserRunnerJSTests/r-kernel-names-drift.test.mjs): the copy cannot
# drift silently because a machine writes it, and the CI format-lint job fails
# when a rewrite would change anything. The one regex parse of Swift source
# lives here, in the generator, rather than in a test per shared constant —
# see docs/language-handling-review.md section 2 for the guard-mechanism
# hierarchy this implements. Add future shared constants as new fenced blocks
# written by this script, not as new bespoke drift tests.
#
# Usage:
#   scripts/generate-js-constants.sh           rewrite the fenced block in place
#   scripts/generate-js-constants.sh --check   exit 1 if a rewrite would change anything
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_src="$repo_root/Sources/Core/AssignmentLanguage.swift"
js_src="$repo_root/Public/browser-runner.js"

mode="write"
if [ "${1:-}" = "--check" ]; then
  mode="check"
fi

# --- Parse the Swift set literal -------------------------------------------
raw="$(sed -n 's/.*rKernelNames: Set<String> = \[\(.*\)\].*/\1/p' "$swift_src")"
if [ -z "$raw" ]; then
  echo "generate-js-constants: could not find rKernelNames in $swift_src" >&2
  exit 1
fi

names="$(printf '%s\n' "$raw" | grep -o '"[^"]*"' | tr -d '"' | LC_ALL=C sort -u)"
if [ -z "$names" ]; then
  echo "generate-js-constants: rKernelNames parsed empty" >&2
  exit 1
fi

# The sniff lowercases before comparing, so an uppercase alias could never match.
if printf '%s\n' "$names" | grep -q '[A-Z]'; then
  echo "generate-js-constants: rKernelNames entries must be lowercase" >&2
  exit 1
fi

joined="$(printf '%s\n' "$names" | awk -v q="'" 'NR > 1 { out = out ", " } { out = out q $0 q } END { print out }')"
generated="    const R_KERNEL_NAMES = [$joined];"

# --- Rewrite the fenced block ----------------------------------------------
begin_marker="CHICKADEE_GENERATED:R_KERNEL_NAMES:BEGIN"
end_marker="CHICKADEE_GENERATED:R_KERNEL_NAMES:END"
for marker in "$begin_marker" "$end_marker"; do
  if ! grep -q "$marker" "$js_src"; then
    echo "generate-js-constants: missing $marker marker in $js_src" >&2
    exit 1
  fi
done

tmp="$(mktemp)"
awk -v repl="$generated" -v begin="$begin_marker" -v end="$end_marker" '
  index($0, begin) { print; print repl; skipping = 1; next }
  index($0, end)   { skipping = 0; print; next }
  skipping { next }
  { print }
' "$js_src" > "$tmp"

if [ "$mode" = "check" ]; then
  if cmp -s "$tmp" "$js_src"; then
    rm -f "$tmp"
    echo "generate-js-constants: OK (browser R_KERNEL_NAMES matches the Swift declaration)"
  else
    echo "generate-js-constants: Public/browser-runner.js R_KERNEL_NAMES is stale." >&2
    echo "Run scripts/generate-js-constants.sh and commit the result." >&2
    diff -u "$js_src" "$tmp" >&2 || true
    rm -f "$tmp"
    exit 1
  fi
else
  if cmp -s "$tmp" "$js_src"; then
    rm -f "$tmp"
    echo "generate-js-constants: already up to date"
  else
    mv "$tmp" "$js_src"
    echo "generate-js-constants: rewrote the R_KERNEL_NAMES block"
  fi
fi
