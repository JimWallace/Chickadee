#!/usr/bin/env bash
# scripts/weekly-digest-render.sh
#
# Writes the weekly digest from the reports that .github/workflows/weekly-digest.yml
# collects. No model reads them: every line of the digest comes from a rule
# below, so the digest needs no API key and cannot be talked into anything.
#
#   scripts/weekly-digest-render.sh DIR OUTPUT
#   scripts/weekly-digest-render.sh --self-test
#
# It writes the digest to OUTPUT and prints the number of items for a person
# (the "Needs a person" bullets) on stdout, for the issue title.
#
# DIR holds one file per source. A source that could not be read holds
# {"error": "..."}, and the digest reports it as a gap, never as "nothing":
#
#   window.txt          the start of the week, as 2026-11-02T00:00:00Z
#   zap-run.json        the newest zap-baseline.yml run: [{conclusion, status, createdAt, url}]
#   zap-issue.json      the open "ZAP Scan Baseline Report" issue: {number, updatedAt, url, body}, or {}
#   zap-rules.tsv       .zap/rules.tsv
#   codeql-alerts.json  the open CodeQL alerts: [{number, rule, severity, created_at, path, line}]
#   kernel-run.json     the newest kernel-currency.yml run: [{conclusion, status, createdAt, url}]
#   kernel.log          that run's failed log, only when it failed
#   flake.json          the newest flake-telemetry tally: {tally}, or {} when there is none
#   dependabot.json     the open Dependabot PRs: [{number, title, url}]
#   swift-currency-run.json  the newest swift-currency.yml run on main
#   macos-run.json      the newest macos-build.yml run on main
#   visual-run.json     the newest scheduled visual-regression.yml run
#                       (each of the three: [{conclusion, status, createdAt, url}])
#
# A person is asked for:
#   * a ZAP scan that did not run this week, ended red, or could not be read;
#   * a ZAP finding whose rule .zap/rules.tsv does not name;
#   * a CodeQL alert created this week at high or critical severity;
#   * a kernel update with a major version bump, or a red currency run that
#     lists no packages (a failed solve, not an update);
#   * open Dependabot PRs;
#   * a weekly check (Swift currency, macOS build, visual regression on main)
#     that ended red, did not run this week, or has no run at all. A red run
#     has its own issue with a brief; the digest names its label and key;
#   * any source that could not be read.
#
# The model that wrote this digest until 2026-11 also read upstream release
# notes for each kernel package. A major version bump is the rule that stands
# in for that judgement. The digest asks for a check, not a hold: the
# re-vendor pull request auto-merges on green CI, usually before the digest
# runs (#2848).
#
# Needs bash and jq: the GitHub-hosted runner has both. The plain Swift CI
# image has no jq, so the self-test runs in the script-self-tests job.

set -uo pipefail

usage() {
  echo "usage: $0 DIR OUTPUT" >&2
  echo "       $0 --self-test" >&2
  exit 2
}

# Prints the error of a source file, or nothing when the file holds data.
source_error() {
  local file="$1"
  if [ ! -s "$file" ]; then
    printf '%s is missing.' "$(basename "$file")"
    return
  fi
  jq -r 'if type == "object" and has("error") then .error else empty end' "$file" 2> /dev/null \
    || printf '%s is not JSON.' "$(basename "$file")"
}

render() {
  local dir="$1" output="$2"
  local since needs=() security=() kernels=() flakes=() deps=() checks=()

  since="$(tr -d '[:space:]' < "$dir/window.txt" 2> /dev/null)"
  if [[ ! "$since" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$ ]]; then
    needs+=("The start of the week could not be read, so nothing below is marked as new.")
    since="9999-12-31T00:00:00Z"
  fi

  # --- ZAP: did the scan run, and is any finding outside the rules? -------
  local err run_state run_at run_url
  err="$(source_error "$dir/zap-run.json")"
  if [ -n "$err" ]; then
    needs+=("The ZAP scan runs could not be read: $err")
    security+=("**ZAP scan.** Unknown: the runs could not be read.")
  elif [ "$(jq 'length' "$dir/zap-run.json")" -eq 0 ]; then
    needs+=("No ZAP baseline run was found. Check that zap-baseline.yml is scheduled.")
    security+=("**ZAP scan.** No run was found.")
  else
    run_state="$(jq -r '.[0] | if .status == "completed" then ((.conclusion | select(. != "")) // "unknown") else (.status // "unknown") end' "$dir/zap-run.json")"
    run_at="$(jq -r '.[0].createdAt // ""' "$dir/zap-run.json")"
    run_url="$(jq -r '.[0].url // ""' "$dir/zap-run.json")"
    security+=("**ZAP scan.** The newest run started $run_at and ended $run_state: $run_url")
    if [[ "$run_at" < "$since" ]]; then
      needs+=("The newest ZAP scan is from $run_at, before this week. Check that zap-baseline.yml still runs: $run_url")
    elif [ "$run_state" != "success" ]; then
      needs+=("The newest ZAP scan ended $run_state: $run_url")
    fi
  fi

  err="$(source_error "$dir/zap-issue.json")"
  if [ -n "$err" ]; then
    needs+=("The ZAP issue could not be read: $err")
    security+=("**ZAP findings.** Unknown: the issue could not be read.")
  elif [ "$(jq 'has("body")' "$dir/zap-issue.json")" != "true" ]; then
    security+=("**ZAP findings.** No open ZAP issue, so the scan reports no alerts.")
  else
    # The action lists each alert as "**Name** [rule] total: N". Only the
    # "New Alerts" part counts; the "Ignored Alerts" part is already accepted.
    local rules uncovered issue_url
    rules="$(grep -v '^[[:space:]]*#' "$dir/zap-rules.tsv" 2> /dev/null | cut -f1 | grep -E '^[0-9]+$' | sort -u)"
    issue_url="$(jq -r '.url // ""' "$dir/zap-issue.json")"
    uncovered="$(jq -r '.body' "$dir/zap-issue.json" \
      | awk '/Ignored Alerts/ { exit } /New Alerts/ { on = 1; next } on' \
      | grep -oE '\*\*[^*]+\*\* \[[0-9]+\]' \
      | sed -E 's/^\*\*([^*]+)\*\* \[([0-9]+)\]$/\2\t\1/' \
      | while IFS=$'\t' read -r rule name; do
        grep -qx "$rule" <<< "$rules" || printf '%s (rule %s)\n' "$name" "$rule"
      done | sort -u)"
    if [ -z "$uncovered" ]; then
      security+=("**ZAP findings.** Every alert in the ZAP issue is under a rule that .zap/rules.tsv accepts: $issue_url")
    else
      local list
      list="$(paste -sd ';' <<< "$uncovered" | sed 's/;/; /g')"
      needs+=("ZAP reports alerts that .zap/rules.tsv does not cover: $list. See $issue_url")
      security+=("**ZAP findings.** Not covered by .zap/rules.tsv: $list.")
    fi
  fi

  # --- CodeQL: what is open, and what is new ------------------------------
  err="$(source_error "$dir/codeql-alerts.json")"
  if [ -n "$err" ]; then
    needs+=("The CodeQL alerts could not be read: $err")
    security+=("**CodeQL.** Unknown: the alerts could not be read.")
  else
    local open new serious
    open="$(jq 'length' "$dir/codeql-alerts.json")"
    new="$(jq -r --arg since "$since" '
      [.[] | select((.created_at // "") >= $since)]
      | .[] | "- \(.severity // "unknown"): \(.rule // "unknown rule") in \(.path // "?"):\(.line // "?") (alert \(.number))"' \
      "$dir/codeql-alerts.json")"
    serious="$(jq --arg since "$since" '
      [.[] | select((.created_at // "") >= $since and ((.severity // "") | test("^(high|critical)$")))] | length' \
      "$dir/codeql-alerts.json")"
    if [ -z "$new" ]; then
      security+=("**CodeQL.** $open open alert(s). None was created this week.")
    else
      security+=("**CodeQL.** $open open alert(s). Created this week:"$'\n'"$new")
    fi
    [ "$serious" -gt 0 ] && needs+=("$serious new high or critical CodeQL alert(s). See the Security section.")
  fi

  # --- Kernels ------------------------------------------------------------
  err="$(source_error "$dir/kernel-run.json")"
  if [ -n "$err" ]; then
    needs+=("The kernel-currency runs could not be read: $err")
    kernels+=("Unknown: the runs could not be read.")
  elif [ "$(jq 'length' "$dir/kernel-run.json")" -eq 0 ]; then
    needs+=("No kernel-currency run was found. Check that kernel-currency.yml is scheduled.")
    kernels+=("No kernel-currency run was found.")
  else
    local k_state k_at k_url
    # A run that has not finished has an empty conclusion; report its status.
    k_state="$(jq -r '.[0] | if (.status // "completed") == "completed" then ((.conclusion | select(. != "")) // "unknown") else .status end' "$dir/kernel-run.json")"
    k_at="$(jq -r '.[0].createdAt // ""' "$dir/kernel-run.json")"
    k_url="$(jq -r '.[0].url // ""' "$dir/kernel-run.json")"
    if [ "$k_state" = "success" ]; then
      kernels+=("The kernels are current (run $k_at): $k_url")
    elif [[ "$k_state" =~ ^(queued|in_progress|waiting|pending|requested)$ ]]; then
      kernels+=("The newest run ($k_at) is $k_state. The previous digest has the last result: $k_url")
    elif [ "$k_state" = "failure" ]; then
      local changes majors
      # The currency check prints one line per package:
      #   VERSION chickadee-python/pillow  12.3.0-h1_0 -> 13.0.0-h2_0
      changes="$(grep -oE '(ADDED|REMOVED|VERSION|BUILD) +[A-Za-z0-9._-]+/[A-Za-z0-9._-]+ +[^ ]+ -> [^ ]+' "$dir/kernel.log" 2> /dev/null \
        | sed -E 's/ +/ /g' | sort -u)"
      if [ -z "$changes" ]; then
        needs+=("The kernel-currency run failed and lists no package changes, so it is a failed check, not an update: $k_url")
        kernels+=("The newest run failed and lists no package changes: $k_url")
      else
        kernels+=("The newest run ($k_at) found these changes. Its scheduled run dispatches an auto-merging re-vendor pull request: $k_url")
        while read -r change pkg have _ want; do
          kernels+=("- $change $pkg: $have to $want")
        done <<< "$changes"
        majors="$(awk '$1 == "VERSION" { split($3, a, /[.-]/); split($5, b, /[.-]/); if (a[1] != b[1]) print $2 }' <<< "$changes" | paste -sd ',' | sed 's/,/, /g')"
        [ -n "$majors" ] && needs+=("A kernel update makes a major version bump: $majors. Read its release notes and check the kernel: the re-vendor pull request auto-merges when its CI is green, so the update may already be live.")
      fi
    else
      needs+=("The newest kernel-currency run ended $k_state: $k_url")
      kernels+=("The newest run ended $k_state: $k_url")
    fi
  fi

  # --- Flakes -------------------------------------------------------------
  err="$(source_error "$dir/flake.json")"
  if [ -n "$err" ]; then
    needs+=("The flake tally could not be read: $err")
    flakes+=("Unknown: the tally could not be read.")
  elif [ "$(jq 'has("tally")' "$dir/flake.json")" = "true" ]; then
    while IFS= read -r line; do flakes+=("$line"); done \
      < <(jq -r '.tally' "$dir/flake.json" | head -n 20)
  else
    flakes+=("No tally this week. An all-zero week posts nothing.")
  fi

  # --- Dependabot ---------------------------------------------------------
  err="$(source_error "$dir/dependabot.json")"
  if [ -n "$err" ]; then
    needs+=("The Dependabot pull requests could not be read: $err")
    deps+=("Unknown: the pull requests could not be read.")
  else
    local count
    count="$(jq 'length' "$dir/dependabot.json")"
    if [ "$count" -eq 0 ]; then
      deps+=("No open Dependabot pull requests.")
    else
      needs+=("$count open Dependabot pull request(s) wait for a merge decision.")
      while IFS= read -r line; do deps+=("$line"); done \
        < <(jq -r '.[] | "- #\(.number) \(.title)"' "$dir/dependabot.json")
    fi
  fi

  # --- Weekly checks on main ----------------------------------------------
  # file|name|workflow|the label and key of the issue that a red run files
  local spec c_file c_name c_workflow c_issue c_state c_at c_url
  for spec in \
    "swift-currency-run.json|Swift package currency|swift-currency.yml|dependency-update-failed, key swift-currency" \
    "macos-run.json|macOS build|macos-build.yml|scheduled-check-failed, key macos-build" \
    "visual-run.json|Visual regression on main|visual-regression.yml|scheduled-check-failed, key visual-main"; do
    IFS='|' read -r c_file c_name c_workflow c_issue <<< "$spec"
    err="$(source_error "$dir/$c_file")"
    if [ -n "$err" ]; then
      needs+=("The $c_name runs could not be read: $err")
      checks+=("**$c_name.** Unknown: the runs could not be read.")
      continue
    fi
    if [ "$(jq 'length' "$dir/$c_file")" -eq 0 ]; then
      needs+=("No $c_name run was found. Check that $c_workflow is scheduled.")
      checks+=("**$c_name.** No run was found.")
      continue
    fi
    # A run that has not finished has an empty conclusion; report its status.
    c_state="$(jq -r '.[0] | if (.status // "completed") == "completed" then ((.conclusion | select(. != "")) // "unknown") else .status end' "$dir/$c_file")"
    c_at="$(jq -r '.[0].createdAt // ""' "$dir/$c_file")"
    c_url="$(jq -r '.[0].url // ""' "$dir/$c_file")"
    checks+=("**$c_name.** The newest run started $c_at and is $c_state: $c_url")
    if [[ "$c_state" =~ ^(queued|in_progress|waiting|pending|requested)$ ]]; then
      continue
    elif [ "$c_state" != "success" ]; then
      needs+=("$c_name ended $c_state: $c_url. Its issue ($c_issue) has a brief for an agent.")
    elif [[ "$c_at" < "$since" ]]; then
      needs+=("The newest $c_name run is from $c_at, before this week. Check that $c_workflow still runs: $c_url")
    fi
  done

  # --- Write ---------------------------------------------------------------
  {
    echo "Weekly digest for the week from $since. A script wrote it from the scheduled reports (scripts/weekly-digest-render.sh); no model read them."
    echo
    echo "## Needs a person"
    echo
    if [ "${#needs[@]}" -eq 0 ]; then
      echo "Nothing this week."
    else
      printf -- '- %s\n' "${needs[@]}"
    fi
    echo
    echo "## Security"
    echo
    printf '%s\n\n' "${security[@]}"
    echo "## Kernels"
    echo
    printf '%s\n' "${kernels[@]}"
    echo
    echo "## Flakes"
    echo
    printf '%s\n' "${flakes[@]}"
    echo
    echo "## Dependabot"
    echo
    printf '%s\n' "${deps[@]}"
    echo
    echo "## Weekly checks on main"
    echo
    printf '%s\n\n' "${checks[@]}"
  } > "$output"

  echo "${#needs[@]}"
}

# --- self-test ---------------------------------------------------------------

self_test() {
  local tmp failures=0 count body
  tmp="$(mktemp -d)"

  pass() { echo "ok   $1"; }
  fail() {
    echo "FAIL $1"
    sed 's/^/     | /' "$tmp/out.md" 2> /dev/null
    failures=$((failures + 1))
  }

  # A quiet week: every source read, nothing for a person.
  fixture() {
    rm -rf "$tmp/d"
    mkdir -p "$tmp/d"
    echo "2026-11-02T00:00:00Z" > "$tmp/d/window.txt"
    echo '[{"conclusion":"success","status":"completed","createdAt":"2026-11-02T07:00:00Z","url":"https://example.com/zap/1"}]' > "$tmp/d/zap-run.json"
    jq -n '{number: 2193, updatedAt: "2026-10-05T15:46:55Z", url: "https://example.com/issues/2193",
      body: "**New Alerts**\n\t- **CSP: script-src unsafe-eval** [10055] total: 5:\n\n**Ignored Alerts**\n\t- **Base64 Disclosure** [10094] total: 12:\n"}' > "$tmp/d/zap-issue.json"
    printf '# comment\n10055\tWARN\t.*\n10094\tIGNORE\t.*\n' > "$tmp/d/zap-rules.tsv"
    echo '[{"number":24,"rule":"js/xss-through-dom","severity":"high","created_at":"2026-08-04T00:00:00Z","path":"Public/suite-table.js","line":538}]' > "$tmp/d/codeql-alerts.json"
    echo '[{"conclusion":"success","createdAt":"2026-11-02T07:00:00Z","url":"https://example.com/kernel/1"}]' > "$tmp/d/kernel-run.json"
    jq -n '{tally: "Week ending 2026-11-02:\n- smoke: 1 red run(s)"}' > "$tmp/d/flake.json"
    echo '[]' > "$tmp/d/dependabot.json"
    local f
    for f in swift-currency-run macos-run visual-run; do
      echo "[{\"conclusion\":\"success\",\"status\":\"completed\",\"createdAt\":\"2026-11-04T05:00:00Z\",\"url\":\"https://example.com/$f/1\"}]" > "$tmp/d/$f.json"
    done
  }

  run() { count="$(render "$tmp/d" "$tmp/out.md")"; body="$(cat "$tmp/out.md")"; }

  fixture
  run
  if [ "$count" = "0" ] && grep -qx 'Nothing this week.' <<< "$body" \
    && grep -q 'ended success: https://example.com/zap/1' <<< "$body" \
    && grep -q '1 open alert(s). None was created this week.' <<< "$body" \
    && grep -q 'The kernels are current' <<< "$body" && grep -q 'smoke: 1 red run' <<< "$body" \
    && grep -q 'The newest run started 2026-11-04T05:00:00Z and is success: https://example.com/macos-run/1' <<< "$body"; then
    pass "a quiet week asks nobody for anything"
  else
    fail "a quiet week asks nobody for anything (count $count)"
  fi

  fixture
  echo '[{"conclusion":"success","status":"completed","createdAt":"2026-10-19T07:00:00Z","url":"https://example.com/zap/0"}]' > "$tmp/d/zap-run.json"
  run
  if [ "$count" = "1" ] && grep -q 'newest ZAP scan is from 2026-10-19' <<< "$body"; then
    pass "flags a ZAP scan older than the week"
  else
    fail "flags a ZAP scan older than the week (count $count)"
  fi

  fixture
  jq '.[0].conclusion = "failure"' "$tmp/d/zap-run.json" > "$tmp/x" && mv "$tmp/x" "$tmp/d/zap-run.json"
  run
  if [ "$count" = "1" ] && grep -q 'newest ZAP scan ended failure' <<< "$body"; then
    pass "flags a red ZAP scan"
  else
    fail "flags a red ZAP scan (count $count)"
  fi

  fixture
  run
  if ! grep -q 'Base64' <<< "$body" && grep -q 'accepts: https://example.com/issues/2193' <<< "$body"; then
    pass "a ZAP issue that is weeks old is not a missing scan"
  else
    fail "a ZAP issue that is weeks old is not a missing scan"
  fi

  fixture
  jq '.body = "**New Alerts**\n\t- **X-Frame-Options Missing** [10020] total: 2:\n\t- **CSP: script-src unsafe-eval** [10055] total: 5:\n"' \
    "$tmp/d/zap-issue.json" > "$tmp/x" && mv "$tmp/x" "$tmp/d/zap-issue.json"
  run
  if [ "$count" = "1" ] && grep -q 'does not cover: X-Frame-Options Missing (rule 10020)' <<< "$body" \
    && ! grep -q 'unsafe-eval (rule' <<< "$body"; then
    pass "flags a ZAP alert outside the rules, and only that one"
  else
    fail "flags a ZAP alert outside the rules, and only that one (count $count)"
  fi

  fixture
  echo '{}' > "$tmp/d/zap-issue.json"
  run
  if [ "$count" = "0" ] && grep -q 'No open ZAP issue' <<< "$body"; then
    pass "no ZAP issue means no alerts"
  else
    fail "no ZAP issue means no alerts (count $count)"
  fi

  fixture
  jq '. + [{"number":30,"rule":"js/path-injection","severity":"critical","created_at":"2026-11-03T00:00:00Z","path":"Public/a.js","line":7},
           {"number":31,"rule":"js/unused","severity":"note","created_at":"2026-11-03T00:00:00Z","path":"Public/b.js","line":9}]' \
    "$tmp/d/codeql-alerts.json" > "$tmp/x" && mv "$tmp/x" "$tmp/d/codeql-alerts.json"
  run
  if [ "$count" = "1" ] && grep -q '1 new high or critical CodeQL alert' <<< "$body" \
    && grep -qx -- '- critical: js/path-injection in Public/a.js:7 (alert 30)' <<< "$body" \
    && grep -qx -- '- note: js/unused in Public/b.js:9 (alert 31)' <<< "$body" \
    && ! grep -q 'alert 24)' <<< "$body"; then
    pass "lists the CodeQL alerts created this week, and flags the serious ones"
  else
    fail "lists the CodeQL alerts created this week, and flags the serious ones (count $count)"
  fi

  fixture
  echo '[{"conclusion":"failure","createdAt":"2026-11-02T07:00:00Z","url":"https://example.com/kernel/2"}]' > "$tmp/d/kernel-run.json"
  printf '%s\n' \
    'currency	Are current?	2026-11-02T07:01:00Z   VERSION chickadee-octave/narwhals  2.27.0-pyh_0 -> 2.27.1-pyh_0' \
    'currency	Are current?	2026-11-02T07:01:00Z   VERSION chickadee-python/pillow    12.3.0-h1_0 -> 13.0.0-h2_0' \
    'currency	Are current?	2026-11-02T07:01:00Z   BUILD   chickadee-python/pyjs-rt   4.0.6-h1_0 -> 4.0.6-h2_0' > "$tmp/d/kernel.log"
  run
  if [ "$count" = "1" ] && grep -q 'major version bump: chickadee-python/pillow\. Read its release notes' <<< "$body" \
    && grep -qx -- '- VERSION chickadee-octave/narwhals: 2.27.0-pyh_0 to 2.27.1-pyh_0' <<< "$body" \
    && grep -qx -- '- BUILD chickadee-python/pyjs-rt: 4.0.6-h1_0 to 4.0.6-h2_0' <<< "$body"; then
    pass "lists kernel changes and flags only a major bump"
  else
    fail "lists kernel changes and flags only a major bump (count $count)"
  fi

  printf 'solving environment-python.yml ... error\n' > "$tmp/d/kernel.log"
  run
  if [ "$count" = "1" ] && grep -q 'lists no package changes, so it is a failed check' <<< "$body"; then
    pass "a red currency run with no packages is a failed check"
  else
    fail "a red currency run with no packages is a failed check (count $count)"
  fi

  fixture
  echo '[{"number":2850,"title":"Bump vapor from 4.120.0 to 4.121.0","url":"https://example.com/pull/2850"}]' > "$tmp/d/dependabot.json"
  run
  if [ "$count" = "1" ] && grep -qx -- '- #2850 Bump vapor from 4.120.0 to 4.121.0' <<< "$body"; then
    pass "lists open Dependabot pull requests"
  else
    fail "lists open Dependabot pull requests (count $count)"
  fi

  fixture
  echo '{"error": "HTTP 403"}' > "$tmp/d/codeql-alerts.json"
  rm "$tmp/d/dependabot.json"
  echo 'not json' > "$tmp/d/kernel-run.json"
  run
  if [ "$count" = "3" ] && grep -q 'CodeQL alerts could not be read: HTTP 403' <<< "$body" \
    && grep -q 'Dependabot pull requests could not be read: dependabot.json is missing' <<< "$body" \
    && grep -q 'kernel-currency runs could not be read: kernel-run.json is not JSON' <<< "$body"; then
    pass "a source that cannot be read is a gap, never nothing"
  else
    fail "a source that cannot be read is a gap, never nothing (count $count)"
  fi

  fixture
  echo '[]' > "$tmp/d/zap-run.json"
  echo '{}' > "$tmp/d/flake.json"
  run
  if [ "$count" = "1" ] && grep -q 'No ZAP baseline run was found' <<< "$body" \
    && grep -q 'An all-zero week posts nothing' <<< "$body"; then
    pass "says so when there is no ZAP run and no tally"
  else
    fail "says so when there is no ZAP run and no tally (count $count)"
  fi

  fixture
  echo '{"error": "HTTP 502"}' > "$tmp/d/flake.json"
  run
  if [ "$count" = "1" ] && grep -q 'flake tally could not be read: HTTP 502' <<< "$body" \
    && ! grep -q 'No tally this week' <<< "$body"; then
    pass "a flake tally that cannot be read is a gap, not a quiet week"
  else
    fail "a flake tally that cannot be read is a gap, not a quiet week (count $count)"
  fi

  fixture
  echo '[{"conclusion":"","status":"in_progress","createdAt":"2026-11-02T07:00:00Z","url":"https://example.com/kernel/3"}]' > "$tmp/d/kernel-run.json"
  run
  if [ "$count" = "0" ] && grep -q 'The newest run (2026-11-02T07:00:00Z) is in_progress' <<< "$body"; then
    pass "a kernel run still in progress asks nobody for anything"
  else
    fail "a kernel run still in progress asks nobody for anything (count $count)"
  fi

  fixture
  echo '[{"conclusion":"failure","status":"completed","createdAt":"2026-11-04T05:00:00Z","url":"https://example.com/macos/2"}]' > "$tmp/d/macos-run.json"
  run
  if [ "$count" = "1" ] && grep -q 'macOS build ended failure: https://example.com/macos/2. Its issue (scheduled-check-failed, key macos-build)' <<< "$body"; then
    pass "flags a red weekly check and names its issue"
  else
    fail "flags a red weekly check and names its issue (count $count)"
  fi

  fixture
  echo '[{"conclusion":"success","status":"completed","createdAt":"2026-10-20T05:00:00Z","url":"https://example.com/visual/0"}]' > "$tmp/d/visual-run.json"
  echo '[]' > "$tmp/d/swift-currency-run.json"
  rm "$tmp/d/macos-run.json"
  run
  if [ "$count" = "3" ] && grep -q 'newest Visual regression on main run is from 2026-10-20' <<< "$body" \
    && grep -q 'No Swift package currency run was found' <<< "$body" \
    && grep -q 'macOS build runs could not be read: macos-run.json is missing' <<< "$body"; then
    pass "a weekly check that is stale, absent or unreadable asks a person"
  else
    fail "a weekly check that is stale, absent or unreadable asks a person (count $count)"
  fi

  fixture
  echo '[{"conclusion":"","status":"in_progress","createdAt":"2026-11-04T05:00:00Z","url":"https://example.com/visual/3"}]' > "$tmp/d/visual-run.json"
  run
  if [ "$count" = "0" ] && grep -q 'and is in_progress: https://example.com/visual/3' <<< "$body"; then
    pass "a weekly check still in progress asks nobody for anything"
  else
    fail "a weekly check still in progress asks nobody for anything (count $count)"
  fi

  rm -rf "$tmp"
  if [ "$failures" -gt 0 ]; then
    echo "weekly-digest-render self-test: $failures failure(s)"
    return 1
  fi
  echo "weekly-digest-render self-test: OK"
}

if [ "${1:-}" = "--self-test" ]; then
  [ $# -eq 1 ] || usage
  self_test
  exit $?
fi

[ $# -eq 2 ] || usage
render "$1" "$2"
