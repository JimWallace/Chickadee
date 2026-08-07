#!/usr/bin/env bash
#
# Boot a vendored xeus kernel in a real headless browser and grade test scripts
# through the real grading worker — the browser-grading paths from #1271. See
# Tools/browser-grading-smoke/smoke.mjs for what each check pins and why the Node
# suite cannot cover it.
#
# Usage:
#   scripts/browser-grading-smoke.sh                  # R on chromium
#   scripts/browser-grading-smoke.sh python           # Python on chromium
#   scripts/browser-grading-smoke.sh lua              # Lua on chromium
#   scripts/browser-grading-smoke.sh octave           # Octave on chromium
#   scripts/browser-grading-smoke.sh r webkit         # the other engine we ship to
#
# Chromium is pre-installed in CI and in the Claude Code environment; the
# PLAYWRIGHT_CHROMIUM_PATH env var points the probe at it when Playwright's own
# browser download was skipped.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
language="${1:-r}"
engine="${2:-chromium}"

cd "$repo_root/Tools/browser-grading-smoke"
npm install --silent --no-audit --no-fund

cd "$repo_root"
node Tools/browser-grading-smoke/smoke.mjs --language "$language" --browser "$engine"
