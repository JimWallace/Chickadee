#!/usr/bin/env bash
# run_tests.sh — Java build + test runner for Chickadee
#
# Usage:
#   run_tests.sh <submission_zip> <testsetup_dir> <manifest_json>
#
# Output:
#   A single RunnerResult JSON document written to stdout.
#   All diagnostic messages go to stderr.
#
# Exit codes:
#   0  — runner completed normally (even if build/tests failed)
#   1  — runner infrastructure error (bad arguments, missing tools, etc.)

set -euo pipefail

RUNNER_VERSION="java-runner/1.0"

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------

if [[ $# -lt 3 ]]; then
    echo "Usage: run_tests.sh <submission_zip> <testsetup_dir> <manifest_json>" >&2
    exit 1
fi

SUBMISSION_ZIP="$1"
TESTSETUP_DIR="$2"
MANIFEST_JSON="$3"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

json_string() {
    # Escape a string for embedding in JSON
    printf '%s' "$1" \
        | sed 's/\\/\\\\/g' \
        | sed 's/"/\\"/g' \
        | sed ':a;N;$!ba;s/\n/\\n/g' \
        | sed 's/\t/\\t/g'
}

emit_build_failure() {
    local compiler_output
    compiler_output=$(json_string "$1")
    cat <<EOF
{
  "runnerVersion": "${RUNNER_VERSION}",
  "buildStatus": "failed",
  "compilerOutput": "${compiler_output}",
  "executionTimeMs": 0,
  "outcomes": []
}
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Validate environment
# ---------------------------------------------------------------------------

for tool in javac java python3; do
    if ! command -v "$tool" &>/dev/null; then
        echo "Required tool not found: $tool" >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Working directory
# ---------------------------------------------------------------------------

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

SUBMISSION_DIR="$WORK_DIR/submission"
CLASSES_DIR="$WORK_DIR/classes"
mkdir -p "$SUBMISSION_DIR" "$CLASSES_DIR"

# ---------------------------------------------------------------------------
# Unpack submission
# ---------------------------------------------------------------------------

echo "Unpacking submission..." >&2
if ! unzip -q "$SUBMISSION_ZIP" -d "$SUBMISSION_DIR" 2>&1; then
    emit_build_failure "Failed to unpack submission zip"
fi

# ---------------------------------------------------------------------------
# Parse manifest (minimal shell JSON parsing via python3)
# ---------------------------------------------------------------------------

read_manifest() {
    python3 - <<PYEOF
import json, sys

with open('$MANIFEST_JSON') as f:
    m = json.load(f)

print(m.get('language', 'java'))
for suite in m.get('testSuites', []):
    tier = suite.get('tier', 'pub')
    class_name = suite.get('className', '')
    module = suite.get('module', '')
    print(f"{tier}:{class_name}:{module}")

# Last line: limits
limits = m.get('limits', {})
print(f"LIMITS:{limits.get('timeLimitSeconds', 10)}:{limits.get('memoryLimitMb', 256)}")
PYEOF
}

MANIFEST_LINES=()
while IFS= read -r line; do
    MANIFEST_LINES+=("$line")
done < <(read_manifest)

LANGUAGE="${MANIFEST_LINES[0]}"
TIME_LIMIT=10
# Parse LIMITS line (last line)
for line in "${MANIFEST_LINES[@]}"; do
    if [[ "$line" == LIMITS:* ]]; then
        TIME_LIMIT=$(echo "$line" | cut -d: -f2)
    fi
done

echo "Language: $LANGUAGE, time limit: ${TIME_LIMIT}s" >&2

# ---------------------------------------------------------------------------
# Locate test class files in testsetup_dir
# ---------------------------------------------------------------------------

TEST_CLASSES_DIR="$TESTSETUP_DIR/classes"
TEST_SRC_DIR="$TESTSETUP_DIR/src"
RUNNER_JAR_DIR="$(dirname "$0")/junit_runner"

# Build classpath: submission classes + test classes + JUnit jars
JUNIT_JARS=""
for jar in "$RUNNER_JAR_DIR"/lib/*.jar; do
    [[ -f "$jar" ]] && JUNIT_JARS="$JUNIT_JARS:$jar"
done
JUNIT_JARS="${JUNIT_JARS#:}"  # strip leading colon

# ---------------------------------------------------------------------------
# Compile student source
# ---------------------------------------------------------------------------

SUBMISSION_SOURCES=$(find "$SUBMISSION_DIR" -name "*.java" 2>/dev/null | tr '\n' ' ')

if [[ -z "$SUBMISSION_SOURCES" ]]; then
    emit_build_failure "No .java source files found in submission"
fi

echo "Compiling student source..." >&2
COMPILE_CP="${CLASSES_DIR}"
[[ -n "$JUNIT_JARS" ]]        && COMPILE_CP="${COMPILE_CP}:${JUNIT_JARS}"
[[ -d "$TEST_CLASSES_DIR" ]]  && COMPILE_CP="${COMPILE_CP}:${TEST_CLASSES_DIR}"

COMPILE_OUTPUT=$( \
    javac -cp "$COMPILE_CP" -d "$CLASSES_DIR" $SUBMISSION_SOURCES 2>&1
) || true

# Check whether javac succeeded (it may have exited non-zero)
if ! javac -cp "$COMPILE_CP" -d "$CLASSES_DIR" $SUBMISSION_SOURCES > /dev/null 2>&1; then
    # Re-run to capture output cleanly
    COMPILE_OUTPUT=$(javac -cp "$COMPILE_CP" -d "$CLASSES_DIR" $SUBMISSION_SOURCES 2>&1 || true)
    emit_build_failure "$COMPILE_OUTPUT"
fi

echo "Compilation succeeded." >&2

# ---------------------------------------------------------------------------
# Run each test suite via MarmosetRunner
# ---------------------------------------------------------------------------

RUN_CP="${CLASSES_DIR}"
[[ -n "$JUNIT_JARS" ]]        && RUN_CP="${RUN_CP}:${JUNIT_JARS}"
[[ -d "$TEST_CLASSES_DIR" ]]  && RUN_CP="${RUN_CP}:${TEST_CLASSES_DIR}"
RUN_CP="${RUN_CP}:${RUNNER_JAR_DIR}"

TOTAL_ELAPSED=0
ALL_OUTCOMES="[]"
FIRST=true

for line in "${MANIFEST_LINES[@]}"; do
    # Skip the language line and limits line
    [[ "$line" == "$LANGUAGE" ]] && continue
    [[ "$line" == LIMITS:* ]]    && continue

    IFS=':' read -r tier class_name module <<< "$line"
    [[ -z "$class_name" ]] && continue

    echo "Running test suite: $class_name (tier=$tier)" >&2

    START_MS=$(($(date +%s%N) / 1000000))

    SUITE_JSON=$( \
        java -cp "$RUN_CP" MarmosetRunner "$class_name" "$tier" "$TIME_LIMIT" 2>&1 1>/tmp/marmoset_stdout_$$
        cat /tmp/marmoset_stdout_$$
    ) || true
    SUITE_JSON=$(cat /tmp/marmoset_stdout_$$ 2>/dev/null || echo "[]")
    rm -f /tmp/marmoset_stdout_$$

    END_MS=$(($(date +%s%N) / 1000000))
    SUITE_ELAPSED=$(( END_MS - START_MS ))
    TOTAL_ELAPSED=$(( TOTAL_ELAPSED + SUITE_ELAPSED ))

    # Merge suite outcomes into ALL_OUTCOMES via python3
    ALL_OUTCOMES=$(python3 - <<PYEOF
import json
existing = $ALL_OUTCOMES
suite = $SUITE_JSON if isinstance($SUITE_JSON, list) else []
print(json.dumps(existing + suite))
PYEOF
    ) || ALL_OUTCOMES="[]"
done

# ---------------------------------------------------------------------------
# Emit final RunnerResult JSON
# ---------------------------------------------------------------------------

python3 - <<PYEOF
import json

outcomes = $ALL_OUTCOMES if isinstance($ALL_OUTCOMES, list) else []

result = {
    "runnerVersion": "${RUNNER_VERSION}",
    "buildStatus": "passed",
    "compilerOutput": None,
    "executionTimeMs": ${TOTAL_ELAPSED},
    "outcomes": outcomes,
}
print(json.dumps(result, indent=2))
PYEOF
