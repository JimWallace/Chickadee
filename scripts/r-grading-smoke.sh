#!/usr/bin/env bash
#
# Boot the vendored xeus-r kernel in a real headless browser and grade R test
# scripts through Public/r-grading-worker.js — the browser-graded-R path from
# #1271. See Tools/r-grading-smoke/smoke.mjs for what each check pins and why
# the Node suite cannot cover it.
#
# Usage:
#   scripts/r-grading-smoke.sh              # chromium
#   scripts/r-grading-smoke.sh webkit       # the other engine we ship to
#
# Chromium is pre-installed in CI and in the Claude Code environment; the
# PLAYWRIGHT_CHROMIUM_PATH env var points the probe at it when Playwright's own
# browser download was skipped.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
engine="${1:-chromium}"

cd "$repo_root/Tools/r-grading-smoke"
npm install --silent --no-audit --no-fund

cd "$repo_root"
node Tools/r-grading-smoke/smoke.mjs --browser "$engine"
