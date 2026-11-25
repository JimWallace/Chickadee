#!/usr/bin/env bash
set -euo pipefail

# The README's badges that carry a hand-written value must match the source of
# that value. Most badges read their value live (the Scorecard score, CI
# status, the coverage floor in test-coverage.yml, the latest release, the
# license), so they cannot drift. The Swift badge is static, because
# shields.io cannot read Package.swift. This check holds it to the
# `swift-tools-version` line, so a toolchain bump cannot leave the README
# behind.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

tools="$(sed -n '1s|^// swift-tools-version:[[:space:]]*\([0-9][0-9]*\.[0-9][0-9]*\).*|\1|p' Package.swift)"
if [ -z "$tools" ]; then
    echo "check-readme-badges: Package.swift has no swift-tools-version on its first line." >&2
    exit 1
fi

badge="$(grep -o 'img\.shields\.io/badge/Swift-[0-9][0-9.]*-' README.md | head -n 1 \
    | sed 's|img\.shields\.io/badge/Swift-\(.*\)-|\1|')"
if [ -z "$badge" ]; then
    echo "check-readme-badges: README.md has no Swift badge (img.shields.io/badge/Swift-<version>-...)." >&2
    exit 1
fi

if [ "$badge" != "$tools" ]; then
    echo "check-readme-badges: the README Swift badge says Swift $badge, but Package.swift declares swift-tools-version $tools." >&2
    echo "Change the badge in README.md to Swift-$tools." >&2
    exit 1
fi

echo "check-readme-badges: OK (Swift $tools)."
