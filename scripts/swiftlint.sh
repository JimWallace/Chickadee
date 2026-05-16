#!/usr/bin/env bash
set -euo pipefail

# Runs SwiftLint against the repo. swift-format owns formatting (see
# scripts/lint.sh and .swift-format); this script enforces the quality /
# correctness layer configured in .swiftlint.yml.
#
# SwiftLint is delivered via the SwiftLintPlugins SwiftPM package (see
# Package.swift). The plugin ships a pre-built binary, so the first
# invocation on a fresh checkout downloads + caches it; subsequent runs are
# fast. `--strict` upgrades warnings to errors so any violation fails CI.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

exec swift package --allow-writing-to-package-directory swiftlint lint --strict
