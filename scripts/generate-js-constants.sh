#!/usr/bin/env bash
#
# Generate JS constants in Public/browser-runner.js from their canonical Swift
# declarations, so the browser copy is machine-written instead of hand-synced.
#
# The browser cannot import Swift, so it needs a copy of every per-language
# kernel-alias set on AssignmentLanguage (Sources/Core/AssignmentLanguage.swift).
# This script owns those copies. Each lives in a fenced block:
#
#   // CHICKADEE_GENERATED:R_KERNEL_NAMES:BEGIN
#   const R_KERNEL_NAMES = ['ir', 'r', 'webr', 'xr'];
#   // CHICKADEE_GENERATED:R_KERNEL_NAMES:END
#
# THE SETS ARE DISCOVERED, NOT LISTED. Every `<lang>KernelNames` declaration in
# the Swift file produces a block. This script used to hardcode `rKernelNames`,
# which meant adding a language silently generated nothing for it and the
# browser kept routing that language's notebooks to Python — the exact
# "enumerated rather than discovered, fails open" shape recorded in
# docs/adding-a-xeus-kernel.md, in the script whose whole job is keeping two
# copies honest.
#
# A discovered set whose fenced block is MISSING from the JS is an error, not a
# skip: a language with no block is a language the browser cannot route.
#
# Generate-and-diff replaces the retired regex-parse drift test
# (Tests/BrowserRunnerJSTests/r-kernel-names-drift.test.mjs): the copy cannot
# drift silently because a machine writes it, and the CI format-lint job fails
# when a rewrite would change anything. The one regex parse of Swift source
# lives here, in the generator, rather than in a test per shared constant —
# see docs/language-handling-review.md section 2 for the guard-mechanism
# hierarchy this implements.
#
# Usage:
#   scripts/generate-js-constants.sh           rewrite the fenced blocks in place
#   scripts/generate-js-constants.sh --check   exit 1 if a rewrite would change anything
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
swift_src="$repo_root/Sources/Core/AssignmentLanguage.swift"
js_src="$repo_root/Public/browser-runner.js"

mode="write"
if [ "${1:-}" = "--check" ]; then
  mode="check"
fi

# --- Discover every <lang>KernelNames declaration ---------------------------
langs="$(sed -n 's/.*static let \([a-zA-Z]*\)KernelNames: Set<String> = \[.*/\1/p' "$swift_src" \
  | LC_ALL=C sort -u)"
if [ -z "$langs" ]; then
  echo "generate-js-constants: found no <lang>KernelNames declarations in $swift_src" >&2
  exit 1
fi

work="$(mktemp)"
cp "$js_src" "$work"

for lang in $langs; do
  raw="$(sed -n "s/.*${lang}KernelNames: Set<String> = \[\(.*\)\].*/\1/p" "$swift_src")"
  if [ -z "$raw" ]; then
    echo "generate-js-constants: could not parse ${lang}KernelNames in $swift_src" >&2
    rm -f "$work"; exit 1
  fi

  names="$(printf '%s\n' "$raw" | grep -o '"[^"]*"' | tr -d '"' | LC_ALL=C sort -u)"
  if [ -z "$names" ]; then
    echo "generate-js-constants: ${lang}KernelNames parsed empty" >&2
    rm -f "$work"; exit 1
  fi

  # The sniff lowercases before comparing, so an uppercase alias could never match.
  if printf '%s\n' "$names" | grep -q '[A-Z]'; then
    echo "generate-js-constants: ${lang}KernelNames entries must be lowercase" >&2
    rm -f "$work"; exit 1
  fi

  upper="$(printf '%s' "$lang" | tr '[:lower:]' '[:upper:]')"
  const_name="${upper}_KERNEL_NAMES"
  joined="$(printf '%s\n' "$names" \
    | awk -v q="'" 'NR > 1 { out = out ", " } { out = out q $0 q } END { print out }')"
  generated="    const ${const_name} = [$joined];"

  begin_marker="CHICKADEE_GENERATED:${const_name}:BEGIN"
  end_marker="CHICKADEE_GENERATED:${const_name}:END"
  for marker in "$begin_marker" "$end_marker"; do
    if ! grep -q "$marker" "$work"; then
      echo "generate-js-constants: missing $marker marker in $js_src." >&2
      echo "AssignmentLanguage declares ${lang}KernelNames, so the browser needs a" >&2
      echo "${const_name} block to route that language's notebooks. Add the fenced" >&2
      echo "block and re-run." >&2
      rm -f "$work"; exit 1
    fi
  done

  tmp="$(mktemp)"
  awk -v repl="$generated" -v begin="$begin_marker" -v end="$end_marker" '
    index($0, begin) { print; print repl; skipping = 1; next }
    index($0, end)   { skipping = 0; print; next }
    skipping { next }
    { print }
  ' "$work" > "$tmp"
  mv "$tmp" "$work"
done

if [ "$mode" = "check" ]; then
  if cmp -s "$work" "$js_src"; then
    rm -f "$work"
    echo "generate-js-constants: OK (browser kernel-name sets match the Swift declarations)"
  else
    echo "generate-js-constants: Public/browser-runner.js kernel-name sets are stale." >&2
    echo "Run scripts/generate-js-constants.sh and commit the result." >&2
    diff -u "$js_src" "$work" >&2 || true
    rm -f "$work"
    exit 1
  fi
else
  if cmp -s "$work" "$js_src"; then
    rm -f "$work"
    echo "generate-js-constants: already up to date"
  else
    mv "$work" "$js_src"
    echo "generate-js-constants: rewrote the kernel-name blocks"
  fi
fi
