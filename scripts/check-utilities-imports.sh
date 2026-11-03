#!/usr/bin/env bash
set -euo pipefail

# Utilities/ holds pure code: no request, no database (#1730).
#
# A file under `Sources/APIServer/Utilities/` may not import Vapor or a
# database module (Fluent, FluentKit, a Fluent driver, SQLKit, SQLiteKit,
# PostgresKit). Code that needs one lives in `Bootstrap/` (app setup),
# `Helpers/` (request-aware helpers) or `Services/` (models and a database).
#
# The boundary is checked from both sides (#2144, #2775). A file under
# `Helpers/` is there because it is the HTTP edge, so its code must name a
# request-layer type (the list is below). A Helpers file that names none is
# database or domain code (it goes to `Services/`) or pure (`Utilities/`).
# A file under `Services/` may not name `Request` and may not have a Helpers
# file name: before #2775, 22 Helpers files never took a request, and three
# Services files were named `*Helpers`.
# Before this guard the boundary leaked both ways: the migration registry and
# a session driver sat in Utilities/, and pure scanners sat in Services/.
# The authoring validators used to be allowed Vapor for `Abort`; they throw
# `AuthoringValidationError` now (#1929), so nothing under Utilities/ may
# import it.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
# shellcheck source=lib/grep-guard.sh
. "scripts/lib/grep-guard.sh"

dir="Sources/APIServer/Utilities"

# An import line, with any attributes (`@preconcurrency`) and an optional
# declaration kind (`import struct Vapor.Abort`), naming a forbidden module.
forbidden='^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|func|var|let|typealias)[[:space:]]+)?(Vapor|Fluent[A-Za-z]*|SQLKit|SQLiteKit|PostgresKit)([^A-Za-z0-9_]|$)'

# Recursive: the renderers sit in subfolders of Utilities/ (#2495).
violations=$(code_matches "$forbidden" "$dir")

if [ -n "$violations" ]; then
  echo "ERROR: a file under $dir imports Vapor or a database module."
  echo
  printf '%s\n' "$violations" | sed 's/^/  /'
  echo
  echo "Utilities/ holds pure code. Move the file to Bootstrap/, Helpers/ or"
  echo "Services/, or remove the import."
  exit 1
fi

# Code text with comments and string literals removed, including the
# multi-line literals that hold generated Python and R, so prose about a type
# never counts as a use of it.
code_text() {
  awk '
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
      print line
    }
  ' "$1"
}

helpers_dir="Sources/APIServer/Helpers"
services_dir="Sources/APIServer/Services"

# The HTTP edge (#2775). A file belongs in Helpers/ when its code names one of
# these Vapor types: it reads a `Request`, builds a `Response`, reads a
# `ClientResponse`, decodes an HTTP body (`Content`, a multipart `File`) or
# maps an error to an HTTP status (`AbortError`). Database and domain logic
# that needs none of them goes to Services/; pure code goes to Utilities/.
http_edge='(^|[^A-Za-z0-9_.])(Request|Response|ClientResponse|Content|File|AbortError)([^A-Za-z0-9_]|$)'
# The request type alone: Services/ may not take or extend one.
request_type='(^|[^A-Za-z0-9_.])Request([^A-Za-z0-9_]|$)'

not_edge=()
# Recursive, as above (#2495).
while IFS= read -r file; do
  # Not `grep -q`: it closes the pipe early, and under pipefail the
  # SIGPIPE to awk would read as no match.
  if code_text "$file" | grep -E "$http_edge" >/dev/null; then continue; fi
  not_edge+=("$file")
done < <(find "$helpers_dir" -name '*.swift' | sort)

if [ "${#not_edge[@]}" -gt 0 ]; then
  echo "ERROR: a file under $helpers_dir names no request-layer type."
  echo
  for file in "${not_edge[@]}"; do
    echo "  $file"
  done
  echo
  echo "Helpers/ holds the HTTP edge: code that names Request, Response,"
  echo "ClientResponse, Content, File or AbortError. Move database and domain"
  echo "code to Services/, and pure code to Utilities/."
  exit 1
fi

takes_request=()
named_helpers=()
while IFS= read -r file; do
  case "$file" in
    *Helpers.swift) named_helpers+=("$file") ;;
  esac
  if code_text "$file" | grep -E "$request_type" >/dev/null; then takes_request+=("$file"); fi
done < <(find "$services_dir" -name '*.swift' | sort)

if [ "${#takes_request[@]}" -gt 0 ]; then
  echo "ERROR: a file under $services_dir names the Request type."
  echo
  for file in "${takes_request[@]}"; do
    echo "  $file"
  done
  echo
  echo "Services/ holds database and domain logic, called with a database or a"
  echo "ServiceContext. Code that reads a Request belongs in Helpers/."
  exit 1
fi

if [ "${#named_helpers[@]}" -gt 0 ]; then
  echo "ERROR: a file under $services_dir has a Helpers name."
  echo
  for file in "${named_helpers[@]}"; do
    echo "  $file"
  done
  echo
  echo "A Helpers file name says the file belongs in Helpers/. Name the file"
  echo "for what it holds."
  exit 1
fi

echo "check-utilities-imports: OK (Utilities/ imports no Vapor or database module; every Helpers/ file names a request-layer type; no Services/ file names Request or has a Helpers name)"
