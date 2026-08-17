#!/usr/bin/env bash
# Writes the CI .env that `docker compose up` needs, and — with --check —
# asserts this script still knows about every variable compose requires.
#
# The gap this closes, which shipped. docker-compose.yml marks a variable as
# mandatory by interpolating it as ${NAME:?message}; compose then refuses to
# start at all if it is unset. #1273 made RUNNER_SHARED_SECRET one of those
# (the runner container stopped mounting the data volume, so the environment
# became its only channel to the HMAC secret). The ZAP baseline workflow wrote
# its own two-line .env inline, was never updated to match, and every scheduled
# run since died at `docker compose up` before a single container started:
#
#     error while interpolating services.server.environment.RUNNER_SHARED_SECRET:
#     required variable RUNNER_SHARED_SECRET is missing a value
#
# Nothing caught it for two weeks, because zap-baseline.yml runs weekly on a
# schedule and has no PR-time signal at all. The compose change was green on its
# own PR and stayed green on every PR after it; the only evidence was a red
# square on a workflow nobody had reason to open.
#
# So the fixture is derived here instead of hand-maintained there, and the
# derivation is checked on every PR by the format-lint job — which is the half
# that matters. A weekly workflow cannot be trusted to report its own drift.
#
# Deliberately an assertion, not a generator. It would be easy to auto-generate
# a value for anything compose demands and always start successfully, but that
# invents semantics for a variable this script knows nothing about: a future
# required DATABASE_HOST would get a random string, the server would boot
# misconfigured, and the scan would fail later and far less legibly than compose
# refusing up front. An unrecognised requirement is therefore a loud failure
# telling a human to decide what the value should be.
#
# Deliberately awk and shell, with no python3. CI runs two similar images and
# they are easy to confuse: the test jobs use chickadee/swift-ci:6.3-noble,
# which .github/docker/ci-image/Dockerfile builds with python3 and friends,
# while format-lint / build / browser-runner-tests run the plain mirror
# chickadee/swift:6.3-noble, which has no python3 — noble does not bundle it.
# The first cut of this guard used python3 and exited 127 in format-lint. A
# guard should depend on nothing its job might not have.
#
# Usage:
#   scripts/ci-compose-env.sh [path]   write the CI .env (default: ./.env)
#   scripts/ci-compose-env.sh --check  verify the table below covers compose
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE="${ROOT_DIR}/docker-compose.yml"

MODE="write"
OUT_PATH="${ROOT_DIR}/.env"
if [ "${1:-}" = "--check" ]; then
  MODE="check"
elif [ -n "${1:-}" ]; then
  OUT_PATH="$1"
fi

# Settings the scan itself needs. These are not compose-required; they select
# the auth mode a scanner can actually log in under.
BASE='AUTH_MODE=local
ENABLE_NON_SSO_AUTH_MODES=true'

# How each compose-REQUIRED variable is satisfied in CI. "random" mints a fresh
# value per run; anything else is used as a literal. Add an entry here when
# compose gains a required variable — and think about which of the two it wants.
#
# Server and runner only need to agree with each other, and nothing in CI
# persists between runs, so a per-run secret is sufficient.
SATISFIERS='RUNNER_SHARED_SECRET=random'

if [ ! -f "$COMPOSE" ]; then
  echo "ci-compose-env: ${COMPOSE} is missing" >&2
  exit 1
fi

# ${NAME:?msg} and ${NAME?msg} are both compose's "required" forms. Lines that
# are wholly a comment are skipped, so the commented-out db / nginx service
# templates cannot contribute a requirement compose will never enforce; a `#`
# mid-line is left alone, since it may sit inside a value or a default message.
# A $${NAME:?} is compose's escape for a literal, not an interpolation.
required="$(
  awk '
    {
      line = $0
      trimmed = line
      sub(/^[ \t]+/, "", trimmed)
      if (substr(trimmed, 1, 1) == "#") next
      while (match(line, /[$][{][A-Za-z_][A-Za-z0-9_]*:?[?]/)) {
        escaped = (RSTART > 1 && substr(line, RSTART - 1, 1) == "$")
        name = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        if (escaped) continue
        sub(/^[$][{]/, "", name)
        sub(/:?[?]$/, "", name)
        print name
      }
    }
  ' "$COMPOSE" | awk '!seen[$0]++'
)"

# Completeness: a parser that silently matches nothing is indistinguishable from
# a compose file with no requirements, and would sail through every check.
if [ -z "$required" ]; then
  echo "ci-compose-env: no required \${VAR:?...} interpolations found in" \
    "docker-compose.yml — this guard is not reading the file" >&2
  exit 1
fi

names_of() { printf '%s\n' "$1" | cut -d= -f1; }
value_of() { printf '%s\n' "$1" | grep "^$2=" | cut -d= -f2-; }
listed() { printf '%s\n' "$2" | grep -qxF "$1"; }

known="$(printf '%s\n%s\n' "$(names_of "$BASE")" "$(names_of "$SATISFIERS")")"

missing=""
for name in $required; do
  listed "$name" "$known" || missing="${missing}${missing:+, }${name}"
done

stale=""
for name in $(names_of "$SATISFIERS"); do
  listed "$name" "$required" || stale="${stale}${stale:+, }${name}"
done

status=0
if [ -n "$missing" ]; then
  echo "ci-compose-env: docker-compose.yml now requires ${missing}, which this" \
    "script does not supply, so \`docker compose up\` will refuse to start in" \
    "CI. Add an entry to SATISFIERS in scripts/ci-compose-env.sh — 'random'" \
    "for a secret, or a literal for anything whose value carries meaning." >&2
  status=1
fi
if [ -n "$stale" ]; then
  echo "ci-compose-env: SATISFIERS lists ${stale}, which docker-compose.yml no" \
    "longer requires. Drop the entry (or move it to BASE if CI still wants" \
    "the value)." >&2
  status=1
fi
[ "$status" -eq 0 ] || exit "$status"

if [ "$MODE" = "check" ]; then
  count="$(printf '%s\n' "$required" | wc -l | tr -d ' ')"
  echo "ci-compose-env: OK (all ${count} compose-required variable(s) supplied:" \
    "$(printf '%s\n' "$required" | sort | tr '\n' ' ' | sed 's/ $//'))."
  exit 0
fi

# 32 bytes of urandom as hex: no shell metacharacters, so the value needs no
# quoting and cannot be misread by compose's .env parser. `head` leads the
# pipeline, so nothing downstream takes a SIGPIPE under `set -o pipefail`.
random_value() { head -c 32 /dev/urandom | od -An -v -tx1 | tr -d ' \n'; }

{
  printf '%s\n' "$BASE"
  for name in $(names_of "$SATISFIERS"); do
    strategy="$(value_of "$SATISFIERS" "$name")"
    if [ "$strategy" = "random" ]; then
      printf '%s=%s\n' "$name" "$(random_value)"
    else
      printf '%s=%s\n' "$name" "$strategy"
    fi
  done
} | sort > "$OUT_PATH"

echo "ci-compose-env: wrote ${OUT_PATH} ($(wc -l < "$OUT_PATH" | tr -d ' ') variable(s))."
