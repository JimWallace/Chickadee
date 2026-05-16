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
# Note: we deliberately do NOT pass `--strict`.  The structural rules
# (function_body_length, cyclomatic_complexity, type_body_length) have
# meaningful warning/error thresholds in .swiftlint.yml — `warning`
# catches "getting long, consider splitting" and `error` catches "this
# is a real outlier."  `--strict` collapses that distinction by
# upgrading every warning to an error, which would either force every
# 100-line route handler to be split (noise) or push the warning
# threshold so high the rule stops mattering.  Without `--strict`,
# SwiftLint exits non-zero only on rules at error severity, while
# still reporting warnings in the output for visibility.
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

exec swift package --allow-writing-to-package-directory swiftlint lint
