#!/usr/bin/env bash
# scripts/ci-agent-failure-reason.sh
#
# Says why a CI agent step failed. .github/actions/claude-agent runs it after
# claude-code-action fails.
#
#   scripts/ci-agent-failure-reason.sh NAME EXECUTION_FILE
#   scripts/ci-agent-failure-reason.sh --self-test
#
# claude-code-action hides the agent's output, because the model's text can
# quote untrusted input. That also hid the API's own answer when the call
# failed before the model ran. From 2026-10-20 every agent workflow failed in
# under a second with zero tokens, and the log said only that Claude "did not
# return structured_output". The checks stayed green, because a model failure
# is not a verdict, and nobody saw it for two weeks.
#
# The rule: the error text is printed only for an error result that used no
# tokens. Then no model ran, and the text is the API's or the CLI's: a bad
# credential, no credit, an unknown model. When the model ran, only the
# result's subtype, turn count and cost are printed, never its text. A CLI
# error can still quote a word of the prompt, which may be untrusted, so the
# text is treated as untrusted too:
#
#   * Control characters and bidi overrides are removed, so it cannot recolour
#     or reorder the log.
#   * It goes through scripts/ci-agent-sanitize.sh, so a line shaped like a
#     credential stops it, and it is cut to a few short lines.
#   * It is printed between ::stop-commands:: markers, so no line of it can
#     run a workflow command. Its first line also becomes a warning annotation,
#     encoded as a workflow command message.
#
# Exit status: 0 in every case but a usage error (2). It is a report, never a
# gate.
#
# Needs bash and jq. The GitHub-hosted runner has both; the plain Swift CI
# image has no jq, so the self-test runs in the script-self-tests job.

set -uo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly sanitizer="$script_dir/ci-agent-sanitize.sh"

usage() {
  echo "usage: $0 NAME EXECUTION_FILE" >&2
  echo "       $0 --self-test" >&2
  exit 2
}

# Encodes text for the message of a workflow command.
encode_message() {
  local s="$1"
  s="${s//'%'/%25}"
  s="${s//$'\r'/%0D}"
  s="${s//$'\n'/%0A}"
  printf '%s' "$s"
}

# Encodes text for a property (title=) of a workflow command.
encode_property() {
  local s
  s="$(encode_message "$1")"
  s="${s//:/%3A}"
  s="${s//,/%2C}"
  printf '%s' "$s"
}

warn() {
  printf '::warning title=%s::%s\n' "$(encode_property "$1 agent")" "$(encode_message "$2")"
}

# Keeps a value from the result message only when it has the expected shape,
# because the file is the CLI's, but this script trusts nothing it prints.
shaped() {
  local value="$1" pattern="$2"
  if [[ "$value" =~ $pattern ]]; then printf '%s' "$value"; else printf 'unknown'; fi
}

report() {
  local name="$1" file="$2"

  if [ ! -s "$file" ]; then
    warn "$name" "The agent step failed and left no execution log, so the reason is unknown."
    return 0
  fi

  # The file holds one JSON array of messages, or one message per line.
  local messages
  if ! messages="$(jq -cs 'flatten | map(select(type == "object"))' "$file" 2> /dev/null)"; then
    warn "$name" "The agent step failed, and its execution log is not JSON, so the reason is unknown."
    return 0
  fi

  local result
  result="$(jq -c 'map(select(.type == "result")) | last // empty' <<< "$messages")"
  if [ -z "$result" ]; then
    warn "$name" "The agent step failed before the CLI wrote a result, so the reason is unknown."
    return 0
  fi

  local subtype turns cost used
  subtype="$(shaped "$(jq -r '.subtype // ""' <<< "$result")" '^[a-z_]{1,40}$')"
  turns="$(shaped "$(jq -r '.num_turns // ""' <<< "$result")" '^[0-9]{1,6}$')"
  cost="$(shaped "$(jq -r '.total_cost_usd // ""' <<< "$result")" '^[0-9.eE+-]{1,24}$')"
  # "none" only for an error result whose cost is zero and whose usage lists
  # no model.
  used="$(jq -r '
    if .is_error != true then "unknown"
    elif (.total_cost_usd | type) != "number" then "unknown"
    elif .total_cost_usd == 0 and ((.modelUsage // {}) | length) == 0 then "none"
    else "some" end' <<< "$result")"

  echo "$name: the agent step failed. Result: $subtype, $turns turn(s), cost $cost USD."

  if [ "$used" = "some" ]; then
    echo "The model ran, so its text is not printed: it can quote untrusted input."
    warn "$name" "The agent step failed after the model ran ($subtype, $turns turn(s)). See the run log."
    return 0
  fi
  if [ "$used" != "none" ]; then
    echo "The result is not an error with zero tokens, so its text is not printed."
    warn "$name" "The agent step failed ($subtype, $turns turn(s)). See the run log."
    return 0
  fi

  # No model ran, so every text here is the API's or the CLI's.
  local tmp
  tmp="$(mktemp -d)"
  jq -r '
    (map(select(.type == "result")) | last | (.result // empty), ((.errors // [])[] | tostring)),
    (.[] | select(.type == "assistant")
      | (.error // empty | tostring),
        ((.message.content // []) | if type == "array" then .[] else empty end
          | select(type == "object" and .type == "text") | .text))
  ' <<< "$messages" 2> /dev/null \
    | LC_ALL=C tr -d '\000-\010\013-\037\177' \
    | LC_ALL=C sed -e $'s/\xe2\x80[\x8e\x8f\xaa-\xae]//g' -e $'s/\xe2\x81[\xa6-\xa9]//g' \
    | grep -v '^[[:space:]]*$' | awk '!seen[$0]++' > "$tmp/raw"

  local status=0
  "$sanitizer" --max-lines 6 --max-width 300 --max-chars 1500 "$tmp/raw" "$tmp/clean" 2> /dev/null || status=$?
  case "$status" in
    0)
      # The sanitizer ends with a blank line, "---" and the footer (see the end
      # of sanitize() in ci-agent-sanitize.sh). Drop them: this text goes to a
      # log, not to a post. The self-test fails if that ending changes.
      local lines
      lines="$(wc -l < "$tmp/clean")"
      awk -v keep="$((lines - 3))" 'NR <= keep' "$tmp/clean" > "$tmp/text"
      local token
      token="$(od -An -N16 -tx1 /dev/urandom 2> /dev/null | tr -d ' \n')"
      [ -n "$token" ] || token="${RANDOM}${RANDOM}${RANDOM}$$"
      echo "The API or the CLI said:"
      echo "::stop-commands::$token"
      sed 's/^/    /' "$tmp/text"
      echo "::$token::"
      warn "$name" "The agent step failed before the model ran: $(grep -m 1 . "$tmp/text")"
      ;;
    1)
      echo "The execution log holds no error text."
      warn "$name" "The agent step failed before the model ran, and the log holds no error text."
      ;;
    3)
      echo "The error text looks like it holds a credential, so it is not printed."
      warn "$name" "The agent step failed before the model ran. Its error text looks like a credential and is not printed."
      ;;
    *)
      echo "The error text could not be cleaned (status $status), so it is not printed."
      warn "$name" "The agent step failed before the model ran. Its error text could not be cleaned."
      ;;
  esac
  rm -rf "$tmp"
  return 0
}

# --- self-test ---------------------------------------------------------------

self_test() {
  local tmp failures=0 out
  tmp="$(mktemp -d)"

  pass() { echo "ok   $1"; }
  fail() {
    echo "FAIL $1"
    printf '%s\n' "$out" | sed 's/^/     | /'
    failures=$((failures + 1))
  }

  # Writes $2 to a file and runs the report on it. The output is in $out.
  run() {
    printf '%s' "$2" > "$tmp/exec.json"
    out="$(report "$1" "$tmp/exec.json")"
  }

  local api_error='[
    {"type": "system", "subtype": "init", "model": "claude-haiku-5-5"},
    {"type": "result", "subtype": "success", "is_error": true, "num_turns": 1,
     "total_cost_usd": 0, "modelUsage": {}, "result": "Invalid API key · Fix external API key"}
  ]'

  run digest "$api_error"
  if grep -qx '    Invalid API key · Fix external API key' <<< "$out" \
    && grep -q '^::warning title=digest agent::The agent step failed before the model ran: Invalid API key' <<< "$out" \
    && grep -q 'Result: success, 1 turn(s), cost 0 USD' <<< "$out"; then
    pass "prints the API error when no model ran"
  else
    fail "prints the API error when no model ran"
  fi

  run digest "$(jq -c '.[]' <<< "$api_error")"
  if grep -qx '    Invalid API key · Fix external API key' <<< "$out"; then
    pass "reads one message per line too"
  else
    fail "reads one message per line too"
  fi

  run review '[{"type": "result", "subtype": "error_max_turns", "is_error": true, "num_turns": 40,
    "total_cost_usd": 0.42, "modelUsage": {"claude-sonnet-5-5": {}}, "result": "MODEL TEXT from the diff"}]'
  if ! grep -q 'MODEL TEXT' <<< "$out" && grep -q 'The model ran, so its text is not printed' <<< "$out" \
    && grep -q 'error_max_turns, 40 turn(s)' <<< "$out"; then
    pass "never prints the text when the model ran"
  else
    fail "never prints the text when the model ran"
  fi

  run review '[{"type": "result", "subtype": "success", "is_error": true, "num_turns": 1,
    "total_cost_usd": 0, "modelUsage": {}, "result": "bad key sk-ant-api03-abcdef"}]'
  if ! grep -q 'sk-ant' <<< "$out" && grep -q 'looks like it holds a credential' <<< "$out"; then
    pass "refuses a credential-shaped error"
  else
    fail "refuses a credential-shaped error"
  fi

  run review '[{"type": "result", "subtype": "success", "is_error": true, "num_turns": 1,
    "total_cost_usd": 0, "modelUsage": {}, "result": "::error::injected\n::set-output name=x::y"}]'
  local token
  token="$(sed -n 's/^::stop-commands::\(.*\)$/\1/p' <<< "$out")"
  if [ -n "$token" ] && grep -qx "::$token::" <<< "$out" \
    && ! grep -qE '^::(error|set-output)' <<< "$out" \
    && grep -qx '    ::error::injected' <<< "$out"; then
    pass "prints the text between stop-commands markers, indented"
  else
    fail "prints the text between stop-commands markers, indented"
  fi

  run review '[{"type": "result", "subtype": "success", "is_error": true, "num_turns": 1,
    "total_cost_usd": 0, "modelUsage": {}, "result": "100% of: a, b"}]'
  if grep -q '^::warning title=review agent::.*100%25 of: a, b$' <<< "$out"; then
    pass "encodes the annotation message"
  else
    fail "encodes the annotation message"
  fi

  run digest '[
    {"type": "assistant", "error": "billing_error",
     "message": {"content": [{"type": "text", "text": "Credit balance is too low"}]}},
    {"type": "result", "subtype": "success", "is_error": true, "num_turns": 1,
     "total_cost_usd": 0, "modelUsage": {}}
  ]'
  if grep -qx '    billing_error' <<< "$out" && grep -qx '    Credit balance is too low' <<< "$out"; then
    pass "prints the error of a synthetic assistant message"
  else
    fail "prints the error of a synthetic assistant message"
  fi

  run review '[{"type": "result", "subtype": "success", "is_error": true, "num_turns": 1,
    "total_cost_usd": 0, "modelUsage": {}, "result": "red \u001b[31mtext\u001b[0m and \u202eesrever"}]'
  if grep -qx '    red \[31mtext\[0m and esrever' <<< "$out" && ! grep -q $'\e' <<< "$out" \
    && ! grep -q $'\xe2\x80\xae' <<< "$out"; then
    pass "removes control characters and bidi overrides"
  else
    fail "removes control characters and bidi overrides"
  fi

  run review '[{"type": "result", "subtype": "success", "is_error": false, "num_turns": 1,
    "total_cost_usd": 0, "modelUsage": {}, "result": "NOT AN ERROR RESULT"}]'
  if ! grep -q 'NOT AN ERROR RESULT' <<< "$out"; then
    pass "prints no text from a result that is not an error"
  else
    fail "prints no text from a result that is not an error"
  fi

  run digest '[{"type": "result", "subtype": "success", "is_error": true, "num_turns": 1,
    "total_cost_usd": 0, "modelUsage": {}}]'
  if grep -q 'holds no error text' <<< "$out"; then
    pass "says so when there is no error text"
  else
    fail "says so when there is no error text"
  fi

  run digest '[{"type": "system", "subtype": "init"}]'
  if grep -q 'before the CLI wrote a result' <<< "$out"; then
    pass "says so when there is no result message"
  else
    fail "says so when there is no result message"
  fi

  run digest 'not json {'
  if grep -q 'is not JSON' <<< "$out"; then pass "says so when the log is not JSON"; else fail "says so when the log is not JSON"; fi

  out="$(report digest "$tmp/missing.json")"
  if grep -q 'left no execution log' <<< "$out"; then
    pass "says so when the log is missing"
  else
    fail "says so when the log is missing"
  fi

  run digest '[{"type": "result", "subtype": "x\n::error::y", "num_turns": "1; rm", "total_cost_usd": 0, "modelUsage": {}}]'
  if grep -q 'Result: unknown, unknown turn(s)' <<< "$out" && ! grep -q '^::error' <<< "$out"; then
    pass "prints a result field only when it has the expected shape"
  else
    fail "prints a result field only when it has the expected shape"
  fi

  rm -rf "$tmp"
  if [ "$failures" -gt 0 ]; then
    echo "ci-agent-failure-reason self-test: $failures failure(s)"
    return 1
  fi
  echo "ci-agent-failure-reason self-test: OK"
}

if [ "${1:-}" = "--self-test" ]; then
  [ $# -eq 1 ] || usage
  self_test
  exit $?
fi

[ $# -eq 2 ] || usage
report "$1" "$2"
