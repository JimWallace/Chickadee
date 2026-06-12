#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# swift-format's --recursive flag is unreliable across directory roots
# (silently traverses but skips files), so we enumerate explicitly.
find Sources Tests -name "*.swift" -print0 | xargs -0 swift-format lint --strict
swift-format lint --strict Package.swift
