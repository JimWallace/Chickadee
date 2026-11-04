#!/usr/bin/env bash
set -euo pipefail

# Signs a throwaway account in to a RUNNING Chickadee and prints its session
# cookie, so the ZAP baseline scan can crawl the signed-in pages.
#
# Why: with no session, the weekly scan reached five URLs (/, /login, /register,
# /robots.txt, /sitemap.xml). Every student, staff and admin page redirected to
# /login, so the scan covered almost none of the application (#2193).
#
# What it sets up, on the CI server that zap-baseline.yml starts and tears
# down. Nothing here can reach a real deployment: the base URL is an argument,
# the job passes http://localhost:8080, and the database is the compose volume
# that `docker compose down -v` deletes.
#
#   * One local account, registered through /register. The database is empty,
#     so the first registrant becomes the deployment admin (AuthRoutes.register).
#     The password is random per run and is printed nowhere.
#   * ZAP101 (Fall 2026), created through /admin/courses with this account
#     as its instructor, so the /instructor pages render as course staff.
#   * ZAP102 (Fall 2026), created with no instructor and joined through
#     /account/enroll, so the same account is also a student there and the
#     student dashboard lists a course.
#
# One account, not one per role, because one baseline run writes the one
# report issue the weekly digest reads, and a run carries one session. Roles
# are per course (#417), so a single account is an instructor in one course
# and a student in another, and an admin besides. The cost: the student pages
# are seen by a viewer who is also an admin. A page that renders differently
# for an admin who is enrolled as a student is not covered.
#
# Every POST carries the session's CSRF token. One token serves them all: the
# middleware checks a token against the session secret only (CSRFMiddleware).
#
# Each step checks the status and Location it expects and fails loudly
# otherwise, so a change to a form is a red step here, not a scan that
# silently falls back to the login page.
#
# Usage:
#   scripts/zap-signed-in-session.sh <base-url>
# Prints the value of the vapor-session cookie on stdout.

base="${1:?usage: zap-signed-in-session.sh <base-url>}"
base="${base%/}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
jar="$work/cookies.txt"

username="zap-scan"
password="$(openssl rand -hex 24)"
year="2026"
season="fall"

fail() {
  echo "zap-signed-in-session: $*" >&2
  exit 1
}

# request METHOD PATH [curl args...] -> writes "status location" to stdout.
request() {
  local method="$1" path="$2"
  shift 2
  curl -sS -o "$work/body.html" -b "$jar" -c "$jar" -X "$method" \
    -w '%{http_code} %{redirect_url}' "$@" "$base$path"
}

# csrf_from PATH -> the _csrf value on that page.
csrf_from() {
  local result token
  result="$(request GET "$1")"
  [ "${result%% *}" = "200" ] || fail "GET $1 answered '$result', expected 200"
  token="$(grep -o '<input[^>]*name="_csrf"[^>]*>' "$work/body.html" \
    | head -n 1 | sed -n 's/.*value="\([^"]*\)".*/\1/p')"
  [ -n "$token" ] || fail "GET $1 rendered no _csrf field"
  printf '%s' "$token"
}

# expect_redirect RESULT DESCRIPTION LOCATION-PATTERN
expect_redirect() {
  local status="${1%% *}" location="${1#* }"
  case "$status" in
    302 | 303) ;;
    *) fail "$2 answered '$1', expected a redirect" ;;
  esac
  # shellcheck disable=SC2254
  case "$location" in
    $3) ;;
    *) fail "$2 redirected to '$location', expected $3" ;;
  esac
}

# 1. Register. The first account on an empty database is the admin.
token="$(csrf_from /register)"
result="$(request POST /register \
  --data-urlencode "_csrf=$token" \
  --data-urlencode "username=$username" \
  --data-urlencode "password=$password")"
expect_redirect "$result" "POST /register" "$base/*"
case "${result#* }" in
  *error=*) fail "POST /register was refused: ${result#* }" ;;
esac

# 2. The staff course, with this account as its instructor. Being the admin is
#    checked here too: /admin/courses/new answers 200 only to an admin.
token="$(csrf_from /admin/courses/new)"
result="$(request POST /admin/courses \
  --data-urlencode "_csrf=$token" \
  --data-urlencode "code=ZAP101" \
  --data-urlencode "name=ZAP scan staff course" \
  --data-urlencode "termYear=$year" \
  --data-urlencode "termSeason=$season" \
  --data-urlencode "instructor=$username")"
expect_redirect "$result" "POST /admin/courses (staff)" "$base/admin/courses/*"
case "${result#* }" in
  *error=*) fail "POST /admin/courses (staff) was refused: ${result#* }" ;;
esac

# 3. The student course: no instructor, open enrollment (the default), joined
#    by the same account.
result="$(request POST /admin/courses \
  --data-urlencode "_csrf=$token" \
  --data-urlencode "code=ZAP102" \
  --data-urlencode "name=ZAP scan student course" \
  --data-urlencode "termYear=$year" \
  --data-urlencode "termSeason=$season")"
expect_redirect "$result" "POST /admin/courses (student)" "$base/admin/courses/*"
student_course="${result##*/admin/courses/}"
student_course="${student_course%%[?#]*}"
case "$student_course" in
  *[!0-9A-Fa-f-]* | "") fail "POST /admin/courses (student) gave no course ID: ${result#* }" ;;
esac

result="$(request POST /account/enroll \
  --data-urlencode "_csrf=$token" \
  --data-urlencode "courseID=$student_course")"
expect_redirect "$result" "POST /account/enroll" "$base/account"

# 4. The dashboard answers as a signed-in page, not a redirect to /login.
result="$(request GET /)"
[ "${result%% *}" = "200" ] || fail "GET / answered '$result' with the session, expected 200"

cookie="$(awk '$6 == "vapor-session" { print $7 }' "$jar" | tail -n 1)"
[ -n "$cookie" ] || fail "no vapor-session cookie in the jar"
printf '%s\n' "$cookie"
