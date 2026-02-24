#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

version_file="$repo_root/VERSION"
source_file="$repo_root/Sources/Core/ChickadeeVersion.swift"

if [[ ! -f "$version_file" ]]; then
  echo "ERROR: missing VERSION file at $version_file" >&2
  exit 1
fi

if [[ ! -f "$source_file" ]]; then
  echo "ERROR: missing version source file at $source_file" >&2
  exit 1
fi

declared_version="$(tr -d '[:space:]' < "$version_file")"
code_version="$(rg -o --replace '$1' 'current = "([^"]+)"' "$source_file" | head -n 1)"

if [[ -z "$declared_version" ]]; then
  echo "ERROR: VERSION is empty" >&2
  exit 1
fi

if [[ -z "$code_version" ]]; then
  echo "ERROR: could not parse ChickadeeVersion.current from $source_file" >&2
  exit 1
fi

if [[ "$declared_version" != "$code_version" ]]; then
  echo "ERROR: version mismatch" >&2
  echo "  VERSION:                  $declared_version" >&2
  echo "  ChickadeeVersion.current: $code_version" >&2
  exit 1
fi

echo "Version check passed: $declared_version"
