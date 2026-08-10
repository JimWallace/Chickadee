#!/usr/bin/env bash
set -euo pipefail

# No function may default its `language:` parameter to a language.
#
# WHY THIS IS A GUARD AND NOT A CONVENTION. `language: AssignmentLanguage =
# .python` compiles at every call site, forever, and silently renders Python for
# an R, Lua, Octave, C++ or Racket assignment. It is the most expensive shape in
# this codebase, and the defence had already been invented for exactly one
# function: `AssignmentLanguage.resolve` was made non-public because "the
# defaulted parameters made `resolve(manifest: props)` an easy spelling that
# silently skips the notebook sniff". Seventeen other functions carried the same
# hazard, and it cost two real defects before anyone counted them:
#
#   * `family:<id>` dependency tokens expanded to `.py` filenames on every
#     non-Python assignment, and the manifest's dependency validation then
#     rejected the save with a 422 — the assignment could not be saved at all.
#   * The pattern-family filename-collision check compared Python filenames
#     against a non-Python suite and could never collide.
#
# Both were written by someone who had a language in scope and did not pass it,
# because not passing it compiled. A caller that genuinely means Python now says
# so, and that is greppable; a caller that forgot gets a compile error.
#
# This deliberately does NOT ban `?? .python` — a nil-coalescing fallback is a
# separate judgement, made where an assignment legitimately has no language (a
# plain `.sh` suite), and it is visible at the call site rather than hidden in a
# signature.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Any parameter typed `AssignmentLanguage` (optional or not) with a default of a
# language case. Matches across the whole declaration line, which is where
# swift-format puts a defaulted parameter.
offenders=$(grep -rnE "AssignmentLanguage\??[[:space:]]*=[[:space:]]*\." \
  Sources/ 2>/dev/null | sort || true)

if [ -n "$offenders" ]; then
  echo "ERROR: a language parameter carries a default."
  echo
  echo "$offenders" | sed 's/^/  /'
  echo
  echo "A defaulted language compiles at every call site and renders Python for"
  echo "assignments in five other languages. Delete the default and let the"
  echo "compiler name the call sites; each one states the language it means."
  exit 1
fi

count=$(grep -rcE "language: AssignmentLanguage" Sources/ 2>/dev/null \
  | awk -F: '{ total += $2 } END { print total + 0 }')
echo "no-language-defaults: OK ($count language parameter(s), none defaulted)"
