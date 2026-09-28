#!/usr/bin/env bash
set -euo pipefail

# No Foundation `Process` anywhere in the Swift sources or tests.
#
# Every child process goes through swift-subprocess. Foundation's `Process`
# detects a child's exit through a socket the child inherits, and it emulates
# close-on-exec by listing descriptors before `posix_spawn`, so concurrent
# launches leak those sockets into each other's children and one child's exit
# stays invisible for as long as another lives. That stalled worker-tests for
# a week (docs/ci-flakiness.md, Family 6); before it, the same class deadlocked
# the worker's fork (#1139) and crashed the test process inside `Process.run()`
# (the zip path). The last one, the local-runner autostart, moved to
# `SupervisedProcess`.
#
# A long-lived child is `SupervisedProcess`; a one-shot run is `Subprocess.run`
# (see `PersonalizationEvaluator` and Tests/TestSupport/InterpreterSpawn.swift).
#
# Comment lines are skipped, so prose that names the type is fine.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

pattern='(^|[^A-Za-z0-9_])(Foundation\.)?Process(\(\)|\.run\(|\.launchedProcess\()'

hits=$(
  find Sources Tests -name '*.swift' -print0 \
    | xargs -0 grep -nE "$pattern" \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*(//|\*|/\*)' \
    || true
)

if [ -n "$hits" ]; then
  echo "ERROR: Foundation Process launch(es) found. Launch through swift-subprocess"
  echo "       (SupervisedProcess for a long-lived child, Subprocess.run otherwise):"
  printf '%s\n' "$hits" | sed 's/^/  /'
  exit 1
fi

files=$(find Sources Tests -name '*.swift' | wc -l | tr -d ' ')
echo "no-foundation-process: OK ($files Swift file(s), no Foundation Process launch)"
