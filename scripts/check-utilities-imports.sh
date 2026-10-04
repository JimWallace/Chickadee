#!/usr/bin/env bash
set -euo pipefail

# Utilities/ holds pure code: no request, no database (#1730).
#
# A file under `Sources/APIServer/Utilities/` may not import Vapor or a
# database module (Fluent, FluentKit, a Fluent driver, SQLKit, SQLiteKit,
# PostgresKit). Code that needs one lives in `Bootstrap/` (app setup),
# `Helpers/` (request-aware helpers) or `Services/` (models and a database).
# Before this guard the boundary leaked both ways: the migration registry and
# a session driver sat in Utilities/, and pure scanners sat in Services/.
#
# The validators listed below throw `Abort`, Vapor's HTTP error, as the error
# a route returns. They may import Vapor and nothing else from the list above.
# A typed error would remove the need. The list may only shrink: a listed file
# that no longer imports Vapor, or no longer exists, fails too.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dir="Sources/APIServer/Utilities"
abort_validators=(
  PatternFamilyAuthoredGraph.swift
  PatternFamilyValidator.swift
)

# An import line, with any attributes (`@preconcurrency`) and an optional
# declaration kind (`import struct Vapor.Abort`), naming a forbidden module.
forbidden='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?(Vapor|Fluent[A-Za-z]*|SQLKit|SQLiteKit|PostgresKit)([^A-Za-z0-9_]|$)'

is_abort_validator() {
  local name
  for name in "${abort_validators[@]}"; do
    [ "$name" = "$1" ] && return 0
  done
  return 1
}

violations=()
for file in "$dir"/*.swift; do
  name="$(basename "$file")"
  while IFS= read -r line; do
    module="$(printf '%s\n' "$line" | sed -E 's/.*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?([A-Za-z]+).*/\3/')"
    if [ "$module" = "Vapor" ] && is_abort_validator "$name"; then
      continue
    fi
    violations+=("$file: $line")
  done < <(grep -E "$forbidden" "$file" || true)
done

stale=()
for name in "${abort_validators[@]}"; do
  if [ ! -f "$dir/$name" ] || ! grep -qE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+Vapor$' "$dir/$name"; then
    stale+=("$name")
  fi
done

if [ "${#violations[@]}" -gt 0 ]; then
  echo "ERROR: a file under $dir imports Vapor or a database module."
  echo
  for violation in "${violations[@]}"; do
    echo "  $violation"
  done
  echo
  echo "Utilities/ holds pure code. Move the file to Bootstrap/, Helpers/ or"
  echo "Services/, or remove the import."
  exit 1
fi

if [ "${#stale[@]}" -gt 0 ]; then
  echo "ERROR: scripts/check-utilities-imports.sh allows Vapor in a file that no"
  echo "longer imports it."
  echo
  for name in "${stale[@]}"; do
    echo "  $name"
  done
  echo
  echo "The list only shrinks. Delete these names from abort_validators."
  exit 1
fi

echo "check-utilities-imports: OK (${#abort_validators[@]} Abort validator(s) allowed Vapor, nothing else)"
