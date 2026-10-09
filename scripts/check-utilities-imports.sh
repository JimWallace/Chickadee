#!/usr/bin/env bash
set -euo pipefail

# Utilities/ holds pure code: no request, no database (#1730).
#
# A file under `Sources/APIServer/Utilities/` may not import Vapor or a
# database module (Fluent, FluentKit, a Fluent driver, SQLKit, SQLiteKit,
# PostgresKit). Code that needs one lives in `Bootstrap/` (app setup),
# `Helpers/` (request-aware helpers) or `Services/` (models and a database).
#
# The boundary is checked from both sides (#2144). A file under `Helpers/`
# is there because it works with a request, a database driver type or a
# model, so it must import Vapor, Fluent or Leaf, or name a model type
# (`API...`). A Helpers file that does neither is pure and belongs in
# `Utilities/`. Seven such files sat in Helpers/ before this check existed.
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
# Recursive: the renderers sit in subfolders of Utilities/ (#2495).
while IFS= read -r file; do
  while IFS= read -r line; do
    violations+=("$file: $line")
  done < <(grep -E "$forbidden" "$file" || true)
done < <(find "$dir" -name '*.swift' | sort)

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

helpers_dir="Sources/APIServer/Helpers"

# An import of a framework module, with the same attribute and declaration
# kind allowances as above.
framework='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?(Vapor|Fluent[A-Za-z]*|Leaf)([^A-Za-z0-9_]|$)'
# A Fluent model type name: `APIUser`, `APITestSetup`, ... The module's own
# `APIServer` (in every file header) and `APIServerApp` are not models.
model='\bAPI[A-Z][A-Za-z0-9]*\b'

names_a_model() {
  grep -oE "$model" "$1" | grep -vE '^APIServer' | grep -q .
}

pure=()
# Recursive, as above: the Leaf tags sit in Helpers/LeafTags/ (#2495).
while IFS= read -r file; do
  if grep -qE "$framework" "$file"; then continue; fi
  if names_a_model "$file"; then continue; fi
  pure+=("$file")
done < <(find "$helpers_dir" -name '*.swift' | sort)

if [ "${#pure[@]}" -gt 0 ]; then
  echo "ERROR: a file under $helpers_dir imports no Vapor, Fluent or Leaf and names no model."
  echo
  for file in "${pure[@]}"; do
    echo "  $file"
  done
  echo
  echo "Helpers/ holds code that works with a request, a database driver type"
  echo "or a model. A file that uses none of them is pure: move it to Utilities/."
  exit 1
fi

echo "check-utilities-imports: OK (no Vapor or database import under $dir; every Helpers/ file needs Vapor, Fluent, Leaf or a model)"
