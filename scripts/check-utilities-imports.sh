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
# The authoring validators used to be allowed Vapor for `Abort`; they throw
# `AuthoringValidationError` now (#1929), so nothing under Utilities/ may
# import it.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dir="Sources/APIServer/Utilities"

# An import line, with any attributes (`@preconcurrency`) and an optional
# declaration kind (`import struct Vapor.Abort`), naming a forbidden module.
forbidden='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?(Vapor|Fluent[A-Za-z]*|SQLKit|SQLiteKit|PostgresKit)([^A-Za-z0-9_]|$)'

violations=()
for file in "$dir"/*.swift; do
  while IFS= read -r line; do
    violations+=("$file: $line")
  done < <(grep -E "$forbidden" "$file" || true)
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

echo "check-utilities-imports: OK (no Vapor or database import under $dir)"
