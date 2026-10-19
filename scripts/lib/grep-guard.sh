# Shared helper for the grep guards. Source it; do not run it.
#
# code_matches PATTERN PATH... [-- ALLOWED...]
#
# Prints file:line:text, sorted, for each line of a Swift or JavaScript file
# under the PATHs (files or directories, read recursively) that matches the
# extended regex PATTERN. A line that starts with `//` is not read, so the
# documentation of a rule cannot trip it. A comment after code on the same
# line is read; that can only fail the build, never hide a use. The ALLOWED
# paths after `--` are literal file paths whose hits are dropped.
#
# Prints nothing when nothing matches, so a guard tests the result with
# `[ -n "$hits" ]`.
code_matches() {
  local pattern="$1"
  shift
  local paths=()
  while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do
    paths+=("$1")
    shift
  done
  [ "$#" -gt 0 ] && shift
  local hits
  hits=$(grep -rnE --include='*.swift' --include='*.js' -- "$pattern" "${paths[@]}" 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  local allowed
  for allowed in "$@"; do
    hits=$(printf '%s\n' "$hits" | grep -vF "$allowed:" || true)
  done
  printf '%s\n' "$hits" | sed '/^$/d' | sort
}
