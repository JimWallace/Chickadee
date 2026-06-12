#!/usr/bin/env bash
set -euo pipefail

# swift-format: applies the formatting rules in .swift-format in place.
# Companion: scripts/swiftlint.sh runs the SwiftLint quality-rule layer.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# swift-format's --recursive flag is unreliable across directory roots
# (silently traverses but skips files), so we enumerate explicitly.
find Sources Tests -name "*.swift" -print0 | xargs -0 swift-format format --in-place
swift-format format --in-place Package.swift
