#!/usr/bin/env bash
# scripts/dependency-issue.sh
#
# Files, updates or closes one issue labelled `dependency-update-failed`. It is
# the one place where the dependency automation talks to a person: every other
# step of a dependency update (Dependabot opens the PR, dependabot-auto.yml
# regenerates the committed bytes and enables auto-merge, the required checks
# merge it) runs without one. An issue means that the automation stopped and a
# person, or an agent sent by one, has to finish the job.
#
#   scripts/dependency-issue.sh open KEY TITLE BODY_FILE
#   scripts/dependency-issue.sh close KEY COMMENT
#   scripts/dependency-issue.sh keys
#
# KEY names the problem, such as `pr=2863`, `alert=41` or `token`. One open
# issue exists per key. `open` creates the issue, or adds BODY_FILE as a
# comment when an issue for KEY is already open, so a problem that persists
# keeps one thread. `close` closes the open issue for KEY with COMMENT, and
# does nothing when there is none. `keys` prints the key of every open issue.
#
# BODY_FILE holds text from outside the repository (a PR title, a log), so it
# goes through scripts/ci-post-sanitize.sh first. The key marker is appended
# after that, because the sanitizer escapes HTML comments in its input.
#
# The scheduled checks on `main` that are not about a dependency (the macOS
# build, visual regression) use the same issue life cycle under their own
# label. They set ISSUE_LABEL and ISSUE_LABEL_DESCRIPTION in the step's env;
# keys are unique per label, because every lookup filters on it.
#
# Needs GH_TOKEN (issues: write) and GITHUB_REPOSITORY.

set -euo pipefail

LABEL="${ISSUE_LABEL:-dependency-update-failed}"
LABEL_DESCRIPTION="${ISSUE_LABEL_DESCRIPTION:-A dependency update the automation could not land; see scripts/dependency-issue.sh}"
repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

marker() {
  printf '<!-- dependency-issue key=%s -->' "$1"
}

# The number of the open issue for a key, or nothing.
find_issue() {
  local key="$1"
  gh issue list --repo "$repo" --label "$LABEL" --state open --limit 200 \
    --json number,body \
    --jq ".[] | select(.body | contains(\"$(marker "$key")\")) | .number" |
    head -1
}

ensure_label() {
  gh label create "$LABEL" --repo "$repo" --color d93f0b --force \
    --description "$LABEL_DESCRIPTION" >/dev/null
}

cmd="${1:-}"
case "$cmd" in
  open)
    [ "$#" -eq 4 ] || {
      echo "usage: $0 open KEY TITLE BODY_FILE" >&2
      exit 2
    }
    key="$2" title="$3" body_in="$4"
    body="$(mktemp)"
    run_url="${GITHUB_SERVER_URL:-https://github.com}/$repo/actions/runs/${GITHUB_RUN_ID:-0}"
    "$script_dir/ci-post-sanitize.sh" --max-chars 50000 \
      --append "" --append "Filed by $run_url" --append "$(marker "$key")" \
      "$body_in" "$body"
    ensure_label
    existing="$(find_issue "$key")"
    if [ -n "$existing" ]; then
      gh issue comment "$existing" --repo "$repo" --body-file "$body" >/dev/null
      echo "dependency-issue: updated #$existing ($key)"
    else
      url="$(gh issue create --repo "$repo" --label "$LABEL" --title "$title" --body-file "$body")"
      echo "dependency-issue: opened $url ($key)"
    fi
    ;;
  close)
    [ "$#" -eq 3 ] || {
      echo "usage: $0 close KEY COMMENT" >&2
      exit 2
    }
    # A label that does not exist yet would make the lookup fail, not empty.
    ensure_label
    existing="$(find_issue "$2")"
    if [ -n "$existing" ]; then
      gh issue close "$existing" --repo "$repo" --reason completed --comment "$3" >/dev/null
      echo "dependency-issue: closed #$existing ($2)"
    fi
    ;;
  keys)
    gh issue list --repo "$repo" --label "$LABEL" --state open --limit 200 \
      --json body --jq '.[].body' |
      sed -n 's/.*<!-- dependency-issue key=\([^ ]*\) -->.*/\1/p'
    ;;
  *)
    echo "usage: $0 open|close|keys ..." >&2
    exit 2
    ;;
esac
