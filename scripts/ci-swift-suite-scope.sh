#!/usr/bin/env bash
# scripts/ci-swift-suite-scope.sh
#
# Decides how much of the Swift suite in swift-tests.yml a change needs. It
# reads the changed paths, one per line, on stdin, and prints one word:
#
#   full   run every job. This is the answer whenever there is doubt.
#   build  run the build job only, so that it saves the shared .build cache
#          for the new tree. The test lanes skip.
#   skip   skip the build job and the test lanes.
#
#   scripts/ci-swift-suite-scope.sh EVENT [ROOT] < changed-paths
#   scripts/ci-swift-suite-scope.sh --self-test
#
# EVENT is the GitHub event name. ROOT is the repository root (default: the
# root of this checkout). No environment variable is read.
#
# A path cannot affect the Swift suite only when it is one of these Markdown
# files, and no file under Tests/ or Sources/, and not Package.swift, names it:
#
#   docs/**/*.md
#   changelog.d/*.md
#   README.md, CHANGELOG.md, CHANGELOG-<n>.md at the root
#
# "Names it" means that the file contains the repository path of the document,
# or its file name. The file name is not used for README.md, because tests use
# "README.md" as sample data. So docs/README.md can skip, and the root
# README.md, whose path is that sample string, runs the suite.
#
# The rule exists because tests do read documents:
# PageArchetypeTests reads docs/ui-design.md, PythonFallbackCensusTests reads
# docs/language-declaration.md and MCPRoadmapDocSyncTests reads
# docs/mcp-authoring-roadmap.md. A new test that reads a document names it, so
# that document then runs the suite with no change here. A mention in a comment
# also counts. That runs the suite when it was not needed, which is the safe
# direction.
#
# Every other path is relevant: Swift, Public/, scripts/, Tools/, .github/,
# .claude/, CLAUDE.md, and any file that this list does not name.
#
# The release commit. A push whose paths are all skippable documents, or are
# VERSION, CHANGELOG.md, Sources/Core/ChickadeeVersion.swift or a changelog.d
# fragment, is the auto-release commit (or a hand-made one). It answers
# `build`: the version string changes Sources/, so the cache key changes, and
# every later pull request that does not change Swift restores that key. The
# test lanes skip, because the merge commit before it ran them on the same
# code. Only `push` gets this answer. A pull request may not touch those files
# (CLAUDE.md, "Versioning"), so one that does runs the full suite. A document
# that a Swift file names answers `full` on a push too.
#
# merge_group and every other event answer `full`. The merge queue is not
# enabled (docs/release-process.md), so the queue path is never the slow one,
# and the queue is where a semantic conflict is meant to be caught.

set -uo pipefail

repo_root_default="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# True when a file under Tests/ or Sources/, or Package.swift, names the path.
# A grep error (status 2: a missing directory, an unreadable file) also
# answers "named", so that doubt runs the suite.
named_by_swift() {
  local root="$1" path="$2" base status
  base="${path##*/}"
  grep -rqF -- "$path" "$root/Tests" "$root/Sources" "$root/Package.swift" 2> /dev/null
  status=$?
  [ "$status" -ne 1 ] && return 0
  [ "$base" = "README.md" ] && return 1
  grep -rqF -- "$base" "$root/Tests" "$root/Sources" "$root/Package.swift" 2> /dev/null
  status=$?
  [ "$status" -ne 1 ] && return 0
  return 1
}

is_document() {
  case "$1" in
    docs/*.md | changelog.d/*.md | README.md | CHANGELOG.md | CHANGELOG-*.md) ;;
    *) return 1 ;;
  esac
  # changelog.d is flat: a nested path is not a fragment.
  case "$1" in
    changelog.d/*/*) return 1 ;;
  esac
  return 0
}

is_release_file() {
  case "$1" in
    VERSION | CHANGELOG.md | Sources/Core/ChickadeeVersion.swift) return 0 ;;
    changelog.d/*/*) return 1 ;;
    changelog.d/*.md) return 0 ;;
  esac
  return 1
}

decide() {
  local event="$1" root="$2" path seen=0 release=0
  case "$event" in
    pull_request | push) ;;
    *)
      echo full
      return 0
      ;;
  esac
  while IFS= read -r path || [ -n "$path" ]; do
    [ -n "$path" ] || continue
    seen=1
    if is_document "$path"; then
      if named_by_swift "$root" "$path"; then
        echo full
        return 0
      fi
      continue
    fi
    if [ "$event" = push ] && is_release_file "$path"; then
      release=1
      continue
    fi
    echo full
    return 0
  done
  if [ "$seen" -eq 0 ]; then
    echo full
  elif [ "$release" -eq 1 ]; then
    echo build
  else
    echo skip
  fi
}

# --- self-test ---------------------------------------------------------------
# A small repository tree in a temporary directory, so that the cases do not
# depend on which documents the real tests happen to name today.

self_test() {
  local root failures=0
  root="$(mktemp -d)"
  trap 'rm -rf "$root"' RETURN
  mkdir -p "$root/Tests/APITests" "$root/Sources/Core" "$root/docs/archive" "$root/changelog.d"
  printf '// swift-tools-version:6.0\n' > "$root/Package.swift"
  printf 'let doc = "docs/read-by-a-test.md"\n' > "$root/Tests/APITests/DocTests.swift"
  printf '// See named-in-a-comment.md for why.\n' > "$root/Sources/Core/Thing.swift"
  printf 'let sample = "README.md"\n' > "$root/Tests/APITests/SampleTests.swift"

  expect() {
    local want="$1" event="$2" paths="$3" where="${4:-$root}" got
    got="$(printf '%s' "$paths" | decide "$event" "$where")"
    if [ "$got" = "$want" ]; then
      echo "ok    $event [$(printf '%s' "$paths" | tr '\n' ' ')] -> $got"
    else
      echo "FAIL  $event [$(printf '%s' "$paths" | tr '\n' ' ')] -> $got, want $want"
      failures=$((failures + 1))
    fi
  }

  local nl=$'\n'
  expect skip pull_request "docs/plain.md"
  expect skip pull_request "docs/archive/old.md${nl}changelog.d/frag.md${nl}CHANGELOG-0.4.md"
  expect skip pull_request "docs/README.md"
  expect full pull_request "README.md"
  expect skip push "docs/plain.md"
  expect full pull_request "docs/read-by-a-test.md"
  expect full pull_request "docs/archive/named-in-a-comment.md"
  expect full pull_request "docs/plain.md${nl}Sources/Core/Thing.swift"
  expect full pull_request "docs/diagram.png"
  expect full pull_request "Public/styles.css"
  expect full pull_request "CLAUDE.md"
  expect full pull_request "changelog.d/nested/frag.md"
  expect full pull_request ".github/workflows/swift-tests.yml"
  expect full pull_request "scripts/ci-swift-suite-scope.sh"
  expect full pull_request ""
  expect full merge_group "docs/plain.md"
  expect full workflow_dispatch "docs/plain.md"
  expect build push "CHANGELOG.md${nl}VERSION${nl}Sources/Core/ChickadeeVersion.swift${nl}changelog.d/frag.md"
  expect build push "VERSION${nl}docs/plain.md"
  expect full pull_request "CHANGELOG.md${nl}VERSION${nl}Sources/Core/ChickadeeVersion.swift"
  expect full push "VERSION${nl}Sources/Core/Thing.swift"
  expect full push ""
  expect full push "VERSION${nl}changelog.d/README.md${nl}docs/read-by-a-test.md"
  expect full pull_request "docs/plain.md" "/nonexistent-root"

  if [ "$failures" -ne 0 ]; then
    echo "$failures case(s) failed."
    return 1
  fi
  echo "All cases passed."
}

case "${1:-}" in
  --self-test)
    self_test
    exit $?
    ;;
  "")
    echo "usage: $0 EVENT [ROOT] < changed-paths | $0 --self-test" >&2
    exit 2
    ;;
  *)
    decide "$1" "${2:-$repo_root_default}"
    ;;
esac
