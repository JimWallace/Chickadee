#!/usr/bin/env bash
#
# contract-changes.sh: print each path on stdin that is part of the student
# contract (docs/release-gate.md), one per line, in input order.
#
# Usage: <paths on stdin> | scripts/contract-changes.sh [contract-paths file]
#
# The list defaults to scripts/contract-paths.txt beside this script. A
# pattern that ends in / matches everything under that directory; any other
# pattern is a shell glob matched against the whole path. Exits 0 whether or
# not anything matched; the caller tests the output.
#
# `--self-test` checks the matching against the committed list.
set -euo pipefail

if [ "${1:-}" = "--self-test" ]; then
  self="${BASH_SOURCE[0]}"
  input='Public/jupyterlite/build/kernel.wasm
Public/vendorish/x.js
Public/vendor/marked/marked.min.js
Public/runner-wasm/RunnerWasm.abc.wasm
Tools/jupyterlite/environment-r.yml
Tools/jupyterlite/environment.yml
Tools/jupyterlite/requirements.txt
Tools/jupyterlite/requirements.in
Tools/jupyterlite/locks/environment-python-lock.yml
Tools/jupyterlite/chickadee-extension/package.json
Tools/jupyterlite/jupyter-lite.json
Sources/RunnerCore/TestOutcome.swift
Sources/Core/Models/TestOutcomeCollection.swift
Tests/Fixtures/output-contract.json
Tests/Fixtures/other.json
docs/release-gate.md'
  expected='Public/jupyterlite/build/kernel.wasm
Public/vendor/marked/marked.min.js
Public/runner-wasm/RunnerWasm.abc.wasm
Tools/jupyterlite/environment-r.yml
Tools/jupyterlite/requirements.txt
Tools/jupyterlite/requirements.in
Tools/jupyterlite/locks/environment-python-lock.yml
Tools/jupyterlite/jupyter-lite.json
Sources/RunnerCore/TestOutcome.swift
Tests/Fixtures/output-contract.json'
  actual="$(printf '%s\n' "$input" | "$self")"
  if [ "$actual" != "$expected" ]; then
    printf 'contract-changes.sh self-test failed.\nExpected:\n%s\nActual:\n%s\n' "$expected" "$actual" >&2
    exit 1
  fi
  if [ -n "$(printf 'docs/a.md\nREADME.md\n' | "$self")" ]; then
    echo "contract-changes.sh self-test failed: a non-contract path matched" >&2
    exit 1
  fi
  echo "contract-changes.sh self-test: ok"
  exit 0
fi

list="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/contract-paths.txt}"
[ -r "$list" ] || { echo "contract-changes.sh: cannot read $list" >&2; exit 2; }

patterns=()
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  case "$line" in
    '' | '#'*) continue ;;
  esac
  patterns+=("$line")
done < "$list"

while IFS= read -r path || [ -n "$path" ]; do
  [ -n "$path" ] || continue
  for pattern in "${patterns[@]}"; do
    case "$pattern" in
      */)
        if [[ "$path" == "$pattern"* ]]; then
          printf '%s\n' "$path"
          break
        fi
        ;;
      *)
        # shellcheck disable=SC2053
        if [[ "$path" == $pattern ]]; then
          printf '%s\n' "$path"
          break
        fi
        ;;
    esac
  done
done
