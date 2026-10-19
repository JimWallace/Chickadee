#!/usr/bin/env bash
set -euo pipefail

# Runs one Swift test lane of swift-tests.yml, then fails on any skipped test.
#
# The core, api, api-postgres and worker lanes each held the same tail: make the
# xUnit directory, pass `--skip-build` when the shared `.build` cache was an
# exact hit, run `swift test`, then run check-no-skipped-tests.sh on the report.
# Four copies of one branch drift, so the tail lives here (#2719).
#
# Usage: scripts/ci-swift-test-lane.sh REPORT-NAME SWIFT-TEST-ARGUMENT...
#
# REPORT-NAME names the xUnit report, without `.xml`. The arguments go to
# `swift test` unchanged, for example `--filter APITests`.
#
# CACHE_HIT is the `cache-hit` output of the swift-test-setup action. When it is
# `true`, the build job already compiled this exact tree, so the lane skips the
# build. Any other value builds first.

if [ "$#" -lt 1 ]; then
    echo "Usage: scripts/ci-swift-test-lane.sh REPORT-NAME SWIFT-TEST-ARGUMENT..." >&2
    exit 2
fi

report_name="$1"
shift

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

xunit_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xunit"
mkdir -p "$xunit_dir"

build_args=()
if [ "${CACHE_HIT:-}" = "true" ]; then
    build_args=(--skip-build)
fi

swift test ${build_args[@]+"${build_args[@]}"} "$@" --xunit-output "$xunit_dir/$report_name.xml"

# A test that needs an interpreter declares it with a ConditionTrait, so an
# absent tool is a SKIPPED test with a reason, not a silent early return. The CI
# image carries every interpreter, so a skip here is a defect in the image or the
# probe, and this makes it a red job that names the test and the reason.
scripts/check-no-skipped-tests.sh "$xunit_dir"/*-swift-testing.xml
