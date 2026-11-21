#!/usr/bin/env bash
set -uo pipefail

# Prints the 20 slowest Swift test suites of a lane to the job summary.
#
# The lanes (scripts/ci-swift-test-lane.sh) write a Swift Testing xUnit report.
# Swift Testing writes one <testsuite> for the whole run, so this script groups
# the <testcase> elements by suite (`classname`) and adds up their times.
#
# Read the numbers with care. Swift Testing starts a test's clock when it
# schedules the test, not when the test gets a slot, so each time includes the
# wait in the queue (docs/archive/ci-flakiness-history.md, "Tell 2"). A suite's
# total therefore says where the run spent its scheduled time. It is not the
# cost of the suite's bodies. Compare one suite across runs; do not read a total
# as seconds of work.
#
# This is a report, not a check. It never fails the job: a missing or broken
# report prints a note and exits 0.
#
# Usage: scripts/report-slow-suites.sh [REPORT...]
# With no argument it reads every *-swift-testing.xml report in the directory
# that ci-swift-test-lane.sh writes to. It appends to $GITHUB_STEP_SUMMARY when
# that is set, else it prints to stdout.

limit=20
summary="${GITHUB_STEP_SUMMARY:-/dev/stdout}"

if [ "$#" -eq 0 ]; then
    xunit_dir="${RUNNER_TEMP:-${TMPDIR:-/tmp}}/xunit"
    set -- "$xunit_dir"/*-swift-testing.xml
fi

reports=()
for report in "$@"; do
    if [ -f "$report" ]; then
        reports+=("$report")
    fi
done

if [ "${#reports[@]}" -eq 0 ]; then
    echo "report-slow-suites: no xUnit report found, so there is nothing to report."
    exit 0
fi

# One line per suite: total seconds, test count, longest test, suite name.
rows="$(awk '
    /<testcase / {
        suite = ""
        seconds = 0
        if (match($0, /classname="[^"]*"/)) {
            suite = substr($0, RSTART + 11, RLENGTH - 12)
        }
        if (match($0, / time="[^"]*"/)) {
            seconds = substr($0, RSTART + 7, RLENGTH - 8) + 0
        }
        if (suite == "") next
        total[suite] += seconds
        count[suite] += 1
        if (seconds > longest[suite]) longest[suite] = seconds
    }
    END {
        for (suite in total) {
            printf "%.1f\t%d\t%.1f\t%s\n", total[suite], count[suite], longest[suite], suite
        }
    }
' "${reports[@]}" | sort -t "$(printf '\t')" -k1,1 -g -r | head -n "$limit")"

if [ -z "$rows" ]; then
    echo "report-slow-suites: the report holds no test case, so there is nothing to report."
    exit 0
fi

{
    echo "### Slowest suites"
    echo
    echo "The $limit suites with the most scheduled test time in this lane. Each time"
    echo "includes the wait for a slot, so compare a suite across runs and do not read"
    echo "a total as seconds of work (docs/archive/ci-flakiness-history.md)."
    echo
    echo "| Suite | Tests | Total (s) | Longest test (s) |"
    echo "|---|---:|---:|---:|"
    printf '%s\n' "$rows" | awk -F '\t' '{ printf "| `%s` | %s | %s | %s |\n", $4, $2, $1, $3 }'
    echo
} >>"$summary" || echo "report-slow-suites: could not write the summary."

exit 0
