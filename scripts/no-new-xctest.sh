#!/usr/bin/env bash
set -euo pipefail

# Migration complete: every test file is on Swift Testing.  This guard
# asserts that no file under `Tests/` imports XCTest or XCTVapor.
#
# XCTVapor re-exports XCTest and reports request-execution failures via
# `XCTFail`, which is mis-attributed (and intermittently dropped, with a
# "test failures not being reported" warning) when called from a Swift
# Testing `@Test`.  The HTTP-test surface is on Vapor's Swift-Testing-native
# `VaporTesting` module (`app.testing()` + `Issue.record`) instead — see
# Tests/APITests/TestHelpers.swift.  Re-introducing XCTVapor brings the
# flaky bridge back, so it's blocked here too.
#
# If you ever genuinely need XCTest (e.g. measure blocks not yet
# available in Swift Testing), discuss in CLAUDE.md before adding.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

actual=$(grep -rlE "^import (XCTest|XCTVapor)$" Tests/ 2>/dev/null | sort || true)

if [ -n "$actual" ]; then
  echo "ERROR: New file(s) import XCTest/XCTVapor. Use Swift Testing + VaporTesting:"
  echo "$actual" | sed 's/^/  /'
  exit 1
fi

count=$(grep -rl "^import Testing" Tests/ 2>/dev/null | wc -l | tr -d ' ')
echo "no-new-xctest: OK ($count file(s) on Swift Testing; 0 on XCTest/XCTVapor)"
