#!/usr/bin/env bash
set -euo pipefail

# Fails when a Swift Testing xUnit report holds a skipped test.
#
# A test that needs an interpreter declares it with a `ConditionTrait`
# (`@Test(Self.requiresLua)`, `@Test(.ciOnly)`), so an absent tool shows as a
# skipped test with its reason, in the log and in the xUnit report `swift test
# --xunit-output` writes. Before that, the same test returned early from a
# `guard`, and the job stayed green having executed nothing in that language.
# It happened for Rscript, r-base and lua5.4, each on a different image.
#
# The CI image carries every grading interpreter, so on it a skip is a defect
# in the image or in the probe, never an expected state. This guard turns that
# skip into a red job with the test name and the reason on the same line.
#
# Usage: scripts/check-no-skipped-tests.sh REPORT...
# With no argument it reads the sample report under scripts/guard-fixtures/,
# which is how check-guards.sh proves the guard can fail.
#
# A lane that must exclude a test for its own reason (a Postgres-only suite on
# the SQLite lane) excludes it with `swift test --skip`, not with a trait:
# the trait is for a condition the host may not meet, and CI meets all of them.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

if [ "$#" -eq 0 ]; then
    set -- scripts/guard-fixtures/samples/xunit-swift-testing.xml
fi

status=0
reports=0
for report in "$@"; do
    if [ ! -f "$report" ]; then
        echo "ERROR: no xUnit report at $report."
        echo "       Pass the path swift test --xunit-output wrote; Swift Testing adds"
        echo "       -swift-testing before the extension."
        exit 1
    fi
    reports=$((reports + 1))
    if ! grep -q "<testsuite " "$report"; then
        echo "ERROR: $report holds no <testsuite> element, so it is not an xUnit report."
        exit 1
    fi
    skipped="$(grep -c "<skipped" "$report" || true)"
    if [ "$skipped" -eq 0 ]; then
        echo "check-no-skipped-tests: OK ($report, 0 skipped)"
        continue
    fi
    status=1
    echo "ERROR: $skipped skipped test(s) in $report."
    echo "       Every condition a trait names must hold on the CI image. Add the"
    echo "       missing tool to .github/docker/ci-image/Dockerfile and to the"
    echo "       per-job apt fallback in .github/workflows/swift-tests.yml."
    # Each <skipped>reason</skipped> belongs to the <testcase> line before it.
    awk '
        /<testcase / {
            name = $0
            sub(/.*classname="/, "", name); sub(/" name="/, ".", name); sub(/".*/, "", name)
        }
        /<skipped/ {
            reason = $0
            sub(/.*<skipped[^>]*>/, "", reason); sub(/<\/skipped>.*/, "", reason)
            printf "  skipped test %s: %s\n", name, reason
        }
    ' "$report"
done

if [ "$reports" -eq 0 ]; then
    echo "ERROR: no xUnit report was checked."
    exit 1
fi
exit "$status"
