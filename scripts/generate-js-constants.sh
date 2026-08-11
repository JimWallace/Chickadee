#!/usr/bin/env bash
#
# Generate JS constants in Public/browser-runner.js from their canonical Swift
# declarations, so the browser copy is machine-written instead of hand-synced.
#
# The browser cannot import Swift, so it needs a copy of the per-language facts
# it routes on: every kernel-alias set on AssignmentLanguage
# (Sources/Core/AssignmentLanguage.swift), and the union of the graded-script
# extensions on LanguageDescriptor (Sources/Core/LanguageDescriptor.swift).
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
descriptor_src="$repo_root/Sources/Core/LanguageDescriptor.swift"
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

# --- The graded-script extensions, unioned across every descriptor -----------
#
# The browser decides whether a directly-uploaded file is gradeable source (and
# so needs a `.chickadee_student_module` hint) by extension. That list was hand
# written as `.py` / `.r` and silently omitted `.lua`, so a Lua upload got no
# hint and test_runtime.lua — which cannot list a directory and is therefore
# hint-only — could not find it. Generating the union from the descriptors makes
# a new language's extension appear the day its literal does.
extensions="$(sed -n 's/.*scriptExtensions: \[\(.*\)\],.*/\1/p' "$descriptor_src" \
  | grep -o '"[^"]*"' | tr -d '"' | LC_ALL=C sort -u)"
if [ -z "$extensions" ]; then
  echo "generate-js-constants: found no scriptExtensions declarations in $descriptor_src" >&2
  rm -f "$work"; exit 1
fi
if printf '%s\n' "$extensions" | grep -q '[A-Z]'; then
  echo "generate-js-constants: scriptExtensions entries must be lowercase" >&2
  rm -f "$work"; exit 1
fi

ext_joined="$(printf '%s\n' "$extensions" \
  | awk -v q="'" 'NR > 1 { out = out ", " } { out = out q "." $0 q } END { print out }')"
ext_generated="    const GRADED_SCRIPT_EXTENSIONS = [$ext_joined];"
ext_begin="CHICKADEE_GENERATED:GRADED_SCRIPT_EXTENSIONS:BEGIN"
ext_end="CHICKADEE_GENERATED:GRADED_SCRIPT_EXTENSIONS:END"
for marker in "$ext_begin" "$ext_end"; do
  if ! grep -q "$marker" "$work"; then
    echo "generate-js-constants: missing $marker marker in $js_src." >&2
    echo "The browser needs the graded-script extension list to decide which" >&2
    echo "uploads get a student-module hint. Add the fenced block and re-run." >&2
    rm -f "$work"; exit 1
  fi
done

tmp="$(mktemp)"
awk -v repl="$ext_generated" -v begin="$ext_begin" -v end="$ext_end" '
  index($0, begin) { print; print repl; skipping = 1; next }
  index($0, end)   { skipping = 0; print; next }
  skipping { next }
  { print }
' "$work" > "$tmp"
mv "$tmp" "$work"

# --- The per-student inputs filename, per language --------------------------
#
# The browser writes the per-student inputs file into the grading workspace, and
# the filename it writes must be the one that language's test_runtime reads —
# `LanguageDescriptor.inputsFileName`. It was hand-written as four string
# literals, which is how a browser-graded Lua assignment came to write
# `_ck_inputs.py`: the Lua runtime read `_ck_inputs.lua`, found nothing, and
# every per-student value silently went missing. Right marks impossible, no
# error anywhere.
#
# The language token is the enum case, which is exactly what the seed endpoint
# reports, so the JS looks the name up by the value it already has. Every case
# is emitted, including the upload-only ones that never reach a browser: a
# generator that decided which languages "matter" would be one more list to keep
# current.
names_file="$(mktemp)"
# The language token is anchored on the `<lang>Descriptor` stored property each
# descriptor literal is bound to, because that is the only per-language ANCHOR
# in this file that is also part of the literal it names.
#
# It used to anchor on `case .<lang>:` instead, and that broke the day the
# descriptors moved from switch arms to stored properties — a change that was
# semantically neutral and still left the switch in place, so every `case .x:`
# line the parser was looking for was still there, just no longer followed by a
# literal. It paired the LAST case with the FIRST `inputsFileName` and emitted
# `{ racket: '_ck_inputs.py' }`: one plausible-looking row instead of six, which
# is precisely the "browser writes a file the runtime does not read" failure
# this generator exists to prevent, in a new costume.
#
# POSIX awk only — the CI runner has mawk, which does not take gawk's
# three-argument match().
awk '
  /private static let [a-zA-Z]+Descriptor = LanguageDescriptor\(/ {
    if (match($0, /let [a-zA-Z]+Descriptor/)) {
      token = substr($0, RSTART + 4, RLENGTH - 4)
      sub(/Descriptor$/, "", token)
      lang = token
    }
  }
  /inputsFileName: "/ {
    if (lang != "" && match($0, /"[^"]+"/)) {
      print lang, substr($0, RSTART + 1, RLENGTH - 2)
      lang = ""
    }
  }
' "$descriptor_src" | LC_ALL=C sort > "$names_file"
if [ ! -s "$names_file" ]; then
  echo "generate-js-constants: found no inputsFileName declarations in $descriptor_src" >&2
  rm -f "$work" "$names_file"; exit 1
fi

# EVERY language, or fail. The emptiness check above was the only guard, and a
# partial parse is not empty — it is a table that looks right and is missing
# five of six languages. This compares what was parsed against the enum's own
# case count, so the next refactor of the descriptor's shape stops the
# generator instead of quietly shrinking the table.
declared_langs="$(grep -c '^ *case [a-z][a-zA-Z]*$' "$swift_src")"
parsed_langs="$(wc -l < "$names_file" | tr -d ' ')"
if [ "$parsed_langs" -ne "$declared_langs" ]; then
  echo "generate-js-constants: parsed $parsed_langs inputsFileName entries from" >&2
  echo "$descriptor_src, but AssignmentLanguage declares $declared_langs cases." >&2
  echo "The parser anchors the language token on a 'private static let <lang>Descriptor'" >&2
  echo "line; if that shape changed, update the awk block above to match it." >&2
  rm -f "$work" "$names_file"; exit 1
fi

inputs_joined="$(awk -v q="'" 'NR > 1 { out = out ", " } { out = out $1 ": " q $2 q } END { print out }' \
  "$names_file")"
rm -f "$names_file"
inputs_generated="    const INPUTS_FILE_NAMES = { $inputs_joined };"
inputs_begin="CHICKADEE_GENERATED:INPUTS_FILE_NAMES:BEGIN"
inputs_end="CHICKADEE_GENERATED:INPUTS_FILE_NAMES:END"
for marker in "$inputs_begin" "$inputs_end"; do
  if ! grep -q "$marker" "$work"; then
    echo "generate-js-constants: missing $marker marker in $js_src." >&2
    echo "The browser needs the per-student inputs filename for each language, or it" >&2
    echo "writes a file that language's test_runtime does not read. Add the fenced" >&2
    echo "block and re-run." >&2
    rm -f "$work"; exit 1
  fi
done

# --- How each language is spelled to a student ------------------------------
#
# `LanguageDescriptor.displayName` — the browser labels a substrate with it
# ("R grading needs Web Worker support…"), and the raw value is a wire token, so
# "r grading" reads like a typo. Generated for the same reason as everything
# else here: the alternative is a second table of names in JS.
labels_file="$(mktemp)"
awk '
  /private static let [a-zA-Z]+Descriptor = LanguageDescriptor\(/ {
    if (match($0, /let [a-zA-Z]+Descriptor/)) {
      token = substr($0, RSTART + 4, RLENGTH - 4)
      sub(/Descriptor$/, "", token)
      lang = token
    }
  }
  /displayName: "/ {
    if (lang != "" && match($0, /"[^"]+"/)) {
      print lang, substr($0, RSTART + 1, RLENGTH - 2)
      lang = ""
    }
  }
' "$descriptor_src" | LC_ALL=C sort > "$labels_file"
labels_parsed="$(wc -l < "$labels_file" | tr -d ' ')"
if [ "$labels_parsed" -ne "$declared_langs" ]; then
  echo "generate-js-constants: parsed $labels_parsed displayName entries but" >&2
  echo "AssignmentLanguage declares $declared_langs cases." >&2
  rm -f "$work" "$labels_file"; exit 1
fi
labels_joined="$(awk -v q="'" 'NR > 1 { out = out ", " } { out = out $1 ": " q $2 q } END { print out }' \
  "$labels_file")"
rm -f "$labels_file"
labels_generated="    const LANGUAGE_LABELS = { $labels_joined };"
labels_begin="CHICKADEE_GENERATED:LANGUAGE_LABELS:BEGIN"
labels_end="CHICKADEE_GENERATED:LANGUAGE_LABELS:END"
for marker in "$labels_begin" "$labels_end"; do
  if ! grep -q "$marker" "$work"; then
    echo "generate-js-constants: missing $marker marker in $js_src." >&2
    rm -f "$work"; exit 1
  fi
done
tmp="$(mktemp)"
awk -v repl="$labels_generated" -v begin="$labels_begin" -v end="$labels_end" '
  index($0, begin) { print; print repl; skipping = 1; next }
  index($0, end)   { skipping = 0; print; next }
  skipping { next }
  { print }
' "$work" > "$tmp"
mv "$tmp" "$work"

# --- The grading worker each kernel language spawns -------------------------
#
# The browser routes a `.py` test to /python-grading-worker.js, a `.R` to
# /r-grading-worker.js, and so on. That mapping was four hand-written strings in
# browser-runner.js and four more in `NotebookAssetIsolationMiddleware
# .isolatedWorkerScripts`, with nothing connecting them — and forgetting the
# allowlist half is silent by construction: the browser refuses the script on an
# isolated page, `ensureReady` throws, and the submission fails over to the
# native worker with right marks and none of the speed (#1274). Both halves now
# read `EditorSupport.notebookKernel`'s `gradingWorkerScript`.
#
# Keyed by the enum case, which is also the substrate "kind" the router
# computes (`interpreterToKind` maps rscript -> r and is otherwise identity), so
# the lookup needs no translation. Only kernel languages appear: an upload-only
# language has no `notebookKernel` and therefore no worker, which is the whole
# point of the fact living inside that case.
workers_file="$(mktemp)"
awk '
  /private static let [a-zA-Z]+Descriptor = LanguageDescriptor\(/ {
    if (match($0, /let [a-zA-Z]+Descriptor/)) {
      token = substr($0, RSTART + 4, RLENGTH - 4)
      sub(/Descriptor$/, "", token)
      lang = token
    }
  }
  /gradingWorkerScript: "/ {
    if (lang != "" && match($0, /"[^"]+"/)) {
      print lang, substr($0, RSTART + 1, RLENGTH - 2)
      lang = ""
    }
  }
' "$descriptor_src" | LC_ALL=C sort > "$workers_file"
if [ ! -s "$workers_file" ]; then
  echo "generate-js-constants: found no gradingWorkerScript declarations in $descriptor_src" >&2
  rm -f "$work" "$workers_file"; exit 1
fi

workers_joined="$(awk -v q="'" 'NR > 1 { out = out ", " } { out = out $1 ": " q $2 q } END { print out }' \
  "$workers_file")"
rm -f "$workers_file"
workers_generated="    const GRADING_WORKER_SCRIPTS = { $workers_joined };"
workers_begin="CHICKADEE_GENERATED:GRADING_WORKER_SCRIPTS:BEGIN"
workers_end="CHICKADEE_GENERATED:GRADING_WORKER_SCRIPTS:END"
for marker in "$workers_begin" "$workers_end"; do
  if ! grep -q "$marker" "$work"; then
    echo "generate-js-constants: missing $marker marker in $js_src." >&2
    echo "The browser needs the grading worker path for each kernel language, or it" >&2
    echo "cannot route a test to a substrate. Add the fenced block and re-run." >&2
    rm -f "$work"; exit 1
  fi
done

tmp="$(mktemp)"
awk -v repl="$workers_generated" -v begin="$workers_begin" -v end="$workers_end" '
  index($0, begin) { print; print repl; skipping = 1; next }
  index($0, end)   { skipping = 0; print; next }
  skipping { next }
  { print }
' "$work" > "$tmp"
mv "$tmp" "$work"

tmp="$(mktemp)"
awk -v repl="$inputs_generated" -v begin="$inputs_begin" -v end="$inputs_end" '
  index($0, begin) { print; print repl; skipping = 1; next }
  index($0, end)   { skipping = 0; print; next }
  skipping { next }
  { print }
' "$work" > "$tmp"
mv "$tmp" "$work"

if [ "$mode" = "check" ]; then
  if cmp -s "$work" "$js_src"; then
    rm -f "$work"
    echo "generate-js-constants: OK (browser language constants match the Swift declarations)"
  else
    echo "generate-js-constants: Public/browser-runner.js language constants are stale." >&2
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
    echo "generate-js-constants: rewrote the generated language blocks"
  fi
fi
