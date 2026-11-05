#!/usr/bin/env bash
set -euo pipefail

# Runs SwiftLint against the repo. swift-format owns formatting (see
# scripts/lint.sh and .swift-format); this script enforces the quality /
# correctness layer configured in .swiftlint.yml.
#
# SwiftLint is delivered via the SwiftLintPlugins SwiftPM package (see
# Package.swift). The plugin ships a pre-built binary, so the first
# invocation on a fresh checkout downloads + caches it; subsequent runs are
# fast.
#
# Runs with `--strict`: every reported issue, warning or error, fails the
# build.  This is the ratchet that keeps the codebase improving incrementally
# at every change.  PR #524 left us at 0 violations, so this is enforceable
# starting from zero.  If a structural-rule warning threshold (e.g.
# function_body_length at 100 lines) starts causing legitimate friction,
# raise the threshold in .swiftlint.yml rather than dropping --strict.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# SwiftLint loads SourceKit from the active developer directory, and the
# Command Line Tools have none. On a Mac whose xcode-select still points there,
# use Xcode's when Xcode is installed.
xcode_developer=/Applications/Xcode.app/Contents/Developer
if [ "$(uname)" = Darwin ] && [ -z "${DEVELOPER_DIR:-}" ] && [ -d "$xcode_developer" ] \
  && [ "$(xcode-select -p 2>/dev/null)" = /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR="$xcode_developer"
fi

exec swift package --allow-writing-to-package-directory swiftlint lint --strict
