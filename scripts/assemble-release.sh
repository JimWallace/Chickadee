#!/usr/bin/env bash
#
# assemble-release.sh — turn changelog.d/ fragments into a tagged release.
#
# Computes the next version (current VERSION + 1 patch, unless --version is
# given), folds every changelog.d/*.md fragment into a new CHANGELOG.md section
# under "## [Unreleased]", bumps VERSION + Sources/Core/ChickadeeVersion.swift,
# and removes the consumed fragments.
#
# This is the single place a version number is assigned, which is what keeps
# concurrent PRs from colliding on VERSION / ChickadeeVersion / CHANGELOG —
# PRs only ever add a fragment file (see changelog.d/README.md).
#
# Version source of truth is the in-repo VERSION file, not git tags: tags have
# been applied inconsistently, and under this process the auto-release workflow
# owns VERSION, so "current VERSION + 1" is the reliable chain.
#
# Usage:
#   scripts/assemble-release.sh --dry-run        # preview the section, change nothing
#   scripts/assemble-release.sh                  # assemble + bump (used by CI on merge)
#   scripts/assemble-release.sh --version 1.2.3  # force a specific version
#
# Exit codes: 0 ok · 2 bad args · 3 no fragments (nothing to release)

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

dry_run=0
version=""
date_str="$(date -u +%Y-%m-%d)"

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --version) version="${2:?--version needs a value}"; shift ;;
    --date) date_str="${2:?--date needs a value}"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

frag_dir="changelog.d"

# Collect fragment files (everything but the README), sorted. Portable to the
# macOS bash 3.2 used by local dev — no mapfile/readarray.
frags=()
while IFS= read -r f; do
  [ -n "$f" ] && frags+=("$f")
done < <(find "$frag_dir" -maxdepth 1 -type f -name '*.md' ! -name 'README.md' | sort)

if [ "${#frags[@]}" -eq 0 ]; then
  echo "No changelog fragments in $frag_dir/; nothing to release." >&2
  exit 3
fi

if [ -z "$version" ]; then
  current="$(tr -d '[:space:]' < VERSION)"
  IFS=. read -r major minor patch <<<"$current"
  version="${major}.${minor}.$((patch + 1))"
fi

# Build the new CHANGELOG section. Each fragment keeps its own "### Category"
# headings; we stack them under the version header. `trim_blanks` strips leading
# and trailing blank lines from each fragment (portable — no tac/tail -r).
trim_blanks() {
  awk '
    { lines[NR] = $0 }
    END {
      first = 1; while (first <= NR && lines[first] ~ /^[[:space:]]*$/) first++
      last = NR;  while (last >= 1   && lines[last]  ~ /^[[:space:]]*$/) last--
      for (i = first; i <= last; i++) print lines[i]
    }
  ' "$1"
}

section="$(mktemp)"
cleanup() { rm -f "$section" "${section}.cl"; }
trap cleanup EXIT
{
  echo "## [${version}] - ${date_str}"
  echo
  for f in "${frags[@]}"; do
    trim_blanks "$f"
    echo
  done
} > "$section"

if [ "$dry_run" -eq 1 ]; then
  echo "=== would release v${version} (${#frags[@]} fragment(s)) ==="
  cat "$section"
  echo "=== (dry run — no files changed) ==="
  exit 0
fi

# Insert the section immediately after the "## [Unreleased]" marker.
awk -v secfile="$section" '
  { print }
  /^## \[Unreleased\]$/ && !inserted {
    print ""
    while ((getline line < secfile) > 0) print line
    inserted = 1
  }
  END {
    if (!inserted) {
      print "ERROR: no \"## [Unreleased]\" marker in CHANGELOG.md" > "/dev/stderr"
      exit 1
    }
  }
' CHANGELOG.md > "${section}.cl"
mv "${section}.cl" CHANGELOG.md

echo "${version}" > VERSION
printf 'public enum ChickadeeVersion {\n    public static let current = "%s"\n}\n' \
  "${version}" > Sources/Core/ChickadeeVersion.swift

rm -f "${frags[@]}"

echo "${version}"
