#!/usr/bin/env bash
set -euo pipefail

# Shared code must not call up into the routes (#1726).
#
# `Services/`, `Helpers/` and `Utilities/` sit below `Routes/`: a route calls a
# service, never the reverse. Twelve shared files used to call the zip helpers
# in `Routes/Web/`, and four called the one manifest writer there, so the
# layer that serves every directory lived in the one directory nothing else
# should depend on. Those moved to `Helpers/`. This guard stops the next one.
#
# The rule: a file under `Services/`, `Helpers/` or `Utilities/` may not name a
# top-level function or type that is declared only under `Routes/`. A function
# counts when it is called (`name(` not after a `.`); a type counts wherever
# its name appears. Comments and string literals, including the multi-line
# ones that hold generated Python and R, are skipped.
#
# The uses that predate the guard are listed in `scripts/layering-baseline.txt`.
# The list may only shrink: a new symbol fails, and a listed symbol that is no
# longer used fails too, so the list is cut down the day a use goes away.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

baseline_file="scripts/layering-baseline.txt"
shared_dirs=(Sources/APIServer/Services Sources/APIServer/Helpers Sources/APIServer/Utilities)

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Top-level declarations: no indentation, and not private or fileprivate.
decl='^(public |internal |package )?(final )?(func|struct|enum|class|protocol|typealias|actor)[[:space:]]+[A-Za-z_][A-Za-z0-9_]*'
declared_names() {
  sed -E 's/.*(func|struct|enum|class|protocol|typealias|actor)[[:space:]]+//' | sort -u
}
grep -rhoE --include='*.swift' "$decl" Sources/APIServer/Routes | declared_names > "$work/routes"
find Sources -name '*.swift' -not -path 'Sources/APIServer/Routes/*' -print0 \
  | xargs -0 grep -hoE "$decl" | declared_names > "$work/elsewhere"
comm -23 "$work/routes" "$work/elsewhere" > "$work/routes-only"

find "${shared_dirs[@]}" -name '*.swift' -print0 | sort -z | xargs -0 awk -v names_file="$work/routes-only" '
BEGIN { while ((getline name < names_file) > 0) routes_only[name] = 1 }
FNR == 1 { in_multiline = 0 }
{
  line = $0
  quotes = gsub(/"""/, "&", line)
  if (in_multiline) {
    if (quotes % 2 == 1) in_multiline = 0
    next
  }
  if (quotes % 2 == 1) {
    in_multiline = 1
    line = substr(line, 1, index(line, "\"\"\"") - 1)
  }
  gsub(/"([^"\\]|\\.)*"/, "\"\"", line)
  sub(/\/\/.*$/, "", line)
  rest = line
  before = ""
  while (match(rest, /[A-Za-z_][A-Za-z0-9_]*/)) {
    token = substr(rest, RSTART, RLENGTH)
    previous = RSTART > 1 ? substr(rest, RSTART - 1, 1) : before
    after = substr(rest, RSTART + RLENGTH)
    if ((token in routes_only) && previous != ".") {
      if (token !~ /^[a-z]/ || after ~ /^[[:space:]]*\(/) print token "\t" FILENAME ":" FNR
    }
    before = substr(rest, RSTART + RLENGTH - 1, 1)
    rest = after
  }
}' > "$work/uses"

cut -f1 "$work/uses" | sort -u > "$work/used"
{ grep -vE '^[[:space:]]*(#|$)' "$baseline_file" || true; } | sort -u > "$work/baseline"

new_symbols="$(comm -23 "$work/used" "$work/baseline")"
stale_symbols="$(comm -13 "$work/used" "$work/baseline")"

if [ -n "$new_symbols" ]; then
  echo "ERROR: shared code names a symbol defined only under Routes/."
  echo
  for name in $new_symbols; do
    awk -F '\t' -v name="$name" '$1 == name { print "  " name ": " $2 }' "$work/uses"
  done
  echo
  echo "Services/, Helpers/ and Utilities/ sit below Routes/. Move the symbol down"
  echo "to Helpers/ (or the service that owns it), or keep the call in the route."
  exit 1
fi

if [ -n "$stale_symbols" ]; then
  echo "ERROR: $baseline_file lists a symbol that shared code no longer uses."
  echo
  printf '%s\n' "$stale_symbols" | sed 's/^/  /'
  echo
  echo "The baseline only shrinks. Delete these lines from $baseline_file."
  exit 1
fi

echo "check-layering: OK ($(wc -l < "$work/baseline" | tr -d ' ') baselined symbol(s), no new ones)"
