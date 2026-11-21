#!/usr/bin/env bash
# test-db-major-upgrade.sh — End-to-end test of scripts/db-major-upgrade.sh
# against real Docker, real Compose and real Postgres images (#3148).
#
# It needs Docker, so it runs in its own workflow (db-major-upgrade.yml), not in
# script-self-tests. It uses a throwaway Compose project in a temp directory
# built from this repo's docker-compose.yml, and removes every container and
# volume it made on exit.
#
#   OLD_IMAGE     image the database starts on   (default: GHCR mirror of postgres:16)
#   NEW_MAJOR     major version to upgrade to     (default: 18)
#   CHICKADEE_DB_IMAGE_REPO  repository of the new image (default: the GHCR mirror)
#
# Scenarios, in order, on one database:
#   1. preflight refuses while the deploy daemon is not paused; nothing changes
#  1b. --pin-current pins the running image and volume without a restart
#   2. a failure after restore rolls back to the old version, data intact
#   3. a leftover target volume blocks a re-run without --replace-target
#   4. a crash mid-restore leaves the lock; a new run refuses; --recover rolls back
#   5. the upgrade succeeds: version, checksums, roles, grants, RLS, database
#      settings and sequences all carried over
#   6. a second run is a no-op
#   7. a stray `compose up --force-recreate db` keeps the new version and data

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
UPGRADE="$REPO_ROOT/scripts/db-major-upgrade.sh"

MIRROR="${CHICKADEE_TEST_IMAGE_MIRROR:-ghcr.io/jimwallace/chickadee/postgres}"
OLD_IMAGE="${OLD_IMAGE:-$MIRROR:16}"
NEW_MAJOR="${NEW_MAJOR:-18}"
export CHICKADEE_DB_IMAGE_REPO="${CHICKADEE_DB_IMAGE_REPO:-$MIRROR}"
PROJECT="dbupgradetest"

PASS=0
FAIL=0
check() {  # $1 = name, $2 = expected, $3 = actual
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1)); printf 'FAIL  %s\n      expected: %s\n      actual:   %s\n' "$1" "$2" "$3"
  fi
}

TMP="$(mktemp -d)"
export CHICKADEE_COMPOSE_DIR="$TMP/stack"
export CHICKADEE_BACKUP_DIR="$TMP/backups"
export CHICKADEE_STATE_DIR="$TMP/deploy-state"
export CHICKADEE_DB_READY_TIMEOUT_SECS=120
mkdir -p "$CHICKADEE_COMPOSE_DIR" "$CHICKADEE_BACKUP_DIR"

compose() {
  local args=(-f "$CHICKADEE_COMPOSE_DIR/docker-compose.yml")
  [[ -f "$CHICKADEE_COMPOSE_DIR/docker-compose.db.yml" ]] && args+=(-f "$CHICKADEE_COMPOSE_DIR/docker-compose.db.yml")
  docker compose --project-directory "$CHICKADEE_COMPOSE_DIR" "${args[@]}" "$@"
}
q()  { compose exec -T db psql -X -v ON_ERROR_STOP=1 -U chickadee -d chickadee -Atc "$1"; }
mcp() { compose exec -T -e PGPASSWORD=mcp-test-pw db psql -X -h 127.0.0.1 -U chickadee_mcp -d chickadee -Atc "$1"; }
major() { local n; n="$(q 'SHOW server_version_num' 2>/dev/null | tr -d '[:space:]')"; [[ -n "$n" ]] && echo $((n / 10000)); }
wait_ready() {
  local i
  for i in $(seq 1 60); do
    if compose exec -T db pg_isready -q -h 127.0.0.1 -U chickadee >/dev/null 2>&1 && q 'SELECT 1' >/dev/null 2>&1; then return 0; fi
    sleep 2
  done
  return 1
}
show_last_run() { sed 's/^/      | /' "$TMP/last-run.log"; }
# Every run is bounded, so a hang fails with the run's own output instead of
# running into the job timeout with nothing printed.
UPGRADE_TIMEOUT_SECS=300
upgrade() {
  local rc
  timeout "$UPGRADE_TIMEOUT_SECS" "$UPGRADE" "$@" > "$TMP/last-run.log" 2>&1
  rc=$?
  if [[ "$rc" == "124" ]]; then
    printf 'HANG  db-major-upgrade.sh %s did not exit within %ss; its output:\n' "$*" "$UPGRADE_TIMEOUT_SECS" >&2
    show_last_run >&2
  fi
  echo "$rc"
}

cleanup() {
  compose down -v --remove-orphans >/dev/null 2>&1
  docker volume ls -q --filter "name=^${PROJECT}_" | xargs -r docker volume rm >/dev/null 2>&1
  rm -rf "$TMP"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# A Compose stack shaped like production before the upgrade: this repo's
# docker-compose.yml with the db image set back to the old version, and no
# docker-compose.db.yml.
# ---------------------------------------------------------------------------
sed "s#^    image: postgres:[0-9]*\$#    image: $OLD_IMAGE#" "$REPO_ROOT/docker-compose.yml" > "$CHICKADEE_COMPOSE_DIR/docker-compose.yml"
grep -q "image: $OLD_IMAGE" "$CHICKADEE_COMPOSE_DIR/docker-compose.yml" || { echo "could not set the db image in the test compose file" >&2; exit 1; }
"$REPO_ROOT/scripts/ci-compose-env.sh" "$CHICKADEE_COMPOSE_DIR/.env" >/dev/null
printf 'COMPOSE_PROJECT_NAME=%s\nDATABASE_PASSWORD=owner-test-pw\n' "$PROJECT" >> "$CHICKADEE_COMPOSE_DIR/.env"

echo "== starting $OLD_IMAGE"
compose up -d --no-deps db >/dev/null 2>&1 || { compose up -d --no-deps db; exit 1; }
wait_ready || { echo "the old database did not start" >&2; compose logs db; exit 1; }
OLD_MAJOR="$(major)"
echo "   PostgreSQL $OLD_MAJOR is up"

# A small database with everything a dump-only restore tends to lose: a second
# login role, its grants and an RLS policy, database-level grants and settings,
# an extension, a view, a trigger function and advanced sequences.
q "$(cat <<'SQL'
CREATE ROLE chickadee_mcp LOGIN PASSWORD 'mcp-test-pw';
CREATE TABLE _fluent_migrations (id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE, batch int NOT NULL, created_at timestamptz, updated_at timestamptz);
INSERT INTO _fluent_migrations (name, batch) VALUES ('CreateUsers', 1), ('CreateSubmissions', 1), ('AddKind', 2);
CREATE TABLE users (id bigserial PRIMARY KEY, username text NOT NULL UNIQUE, role text NOT NULL,
  updated_at timestamptz);
INSERT INTO users (username, role) SELECT 'user' || g, CASE WHEN g % 10 = 0 THEN 'instructor' ELSE 'student' END
  FROM generate_series(1, 50) g;
CREATE TABLE submissions (id bigserial PRIMARY KEY, user_id bigint NOT NULL REFERENCES users(id),
  body text, kind text NOT NULL DEFAULT 'student');
INSERT INTO submissions (user_id, body, kind)
  SELECT 1 + g % 50, repeat('x', g), CASE WHEN g % 4 = 0 THEN 'secret' ELSE 'student' END
  FROM generate_series(1, 200) g;
CREATE INDEX submissions_kind_idx ON submissions (kind);
CREATE VIEW user_counts AS SELECT role, count(*) AS n FROM users GROUP BY role;
CREATE FUNCTION touch_updated_at() RETURNS trigger LANGUAGE plpgsql AS
  $$BEGIN NEW.updated_at := now(); RETURN NEW; END$$;
CREATE TRIGGER users_touch BEFORE UPDATE ON users FOR EACH ROW EXECUTE FUNCTION touch_updated_at();
ALTER TABLE submissions ENABLE ROW LEVEL SECURITY;
CREATE POLICY mcp_no_secret ON submissions FOR SELECT TO chickadee_mcp USING (kind <> 'secret');
GRANT USAGE ON SCHEMA public TO chickadee_mcp;
GRANT SELECT ON users, submissions, user_counts TO chickadee_mcp;
REVOKE CONNECT ON DATABASE chickadee FROM PUBLIC;
GRANT CONNECT ON DATABASE chickadee TO chickadee_mcp;
ALTER DATABASE chickadee SET statement_timeout = '45s';
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;
SQL
)" >/dev/null || { echo "seeding failed" >&2; exit 1; }
# Sequences past their start, so a restore that loses setval shows up.
q "SELECT nextval('users_id_seq'), nextval('users_id_seq')" >/dev/null
SEED_USERS="$(q 'SELECT count(*) FROM users')"
SEED_SUBS="$(q 'SELECT count(*) FROM submissions')"
SEED_SEQ="$(q "SELECT last_value FROM users_id_seq")"
MCP_VISIBLE="$(mcp 'SELECT count(*) FROM submissions')"
check "seed: the MCP role sees only non-secret rows" "150" "$MCP_VISIBLE"

old_intact() {  # $1 = scenario label
  check "$1: server is back on $OLD_MAJOR" "$OLD_MAJOR" "$(major)"
  check "$1: users intact" "$SEED_USERS" "$(q 'SELECT count(*) FROM users')"
  check "$1: submissions intact" "$SEED_SUBS" "$(q 'SELECT count(*) FROM submissions')"
  check "$1: lock removed" "absent" "$([[ -f "$CHICKADEE_COMPOSE_DIR/.db-upgrade.lock" ]] && echo present || echo absent)"
}

# ---------------------------------------------------------------------------
echo "== 1. preflight refuses while the deploy daemon is running"
mkdir -p "$CHICKADEE_STATE_DIR"
rc="$(upgrade --to "$NEW_MAJOR" --yes --skip-snapshot)"
check "1: refused" "1" "$rc"
check "1: names the daemon" "1" "$(grep -c 'deploy daemon is not paused' "$TMP/last-run.log")"
check "1: still on $OLD_MAJOR" "$OLD_MAJOR" "$(major)"
check "1: no pin file written" "absent" "$([[ -f "$CHICKADEE_COMPOSE_DIR/docker-compose.db.yml" ]] && echo present || echo absent)"
touch "$CHICKADEE_STATE_DIR/paused"

echo "== 1b. --pin-current pins the running database and restarts nothing"
DB_CID_BEFORE="$(compose ps -q db)"
rc="$(upgrade --pin-current)"
check "1b: exit 0" "0" "$rc"
[[ "$rc" == "0" ]] || show_last_run
check "1b: pin file names the old image" "1" "$(grep -c "image: $OLD_IMAGE\$" "$CHICKADEE_COMPOSE_DIR/docker-compose.db.yml" 2>/dev/null)"
check "1b: pin file names the live volume" "1" "$(grep -c "name: ${PROJECT}_chickadee-postgres\$" "$CHICKADEE_COMPOSE_DIR/docker-compose.db.yml" 2>/dev/null)"
check "1b: db container not restarted" "$DB_CID_BEFORE" "$(compose ps -q db)"
compose up -d --no-deps --force-recreate db >/dev/null 2>&1
wait_ready
check "1b: a recreate under the pin keeps $OLD_MAJOR" "$OLD_MAJOR" "$(major)"
check "1b: a recreate under the pin keeps the data" "$SEED_USERS" "$(q 'SELECT count(*) FROM users')"

echo "== 2. a failure after the restore rolls back"
rc="$(CHICKADEE_DB_UPGRADE_TEST_FAIL_AT=restore upgrade --to "$NEW_MAJOR" --yes --skip-snapshot)"
check "2: exit 1" "1" "$rc"
[[ "$rc" == "1" ]] || show_last_run
check "2: says it rolled back" "1" "$(grep -c '^.*rolled back: PostgreSQL' "$TMP/last-run.log")"
old_intact "2"
check "2: MCP role still sees non-secret rows" "150" "$(mcp 'SELECT count(*) FROM submissions')"

echo "== 3. a leftover target volume blocks a plain re-run"
rc="$(upgrade --to "$NEW_MAJOR" --yes --skip-snapshot)"
check "3: refused" "1" "$rc"
check "3: names --replace-target" "1" "$(grep -c 'already exists' "$TMP/last-run.log")"
check "3: still on $OLD_MAJOR" "$OLD_MAJOR" "$(major)"

echo "== 4. a crash mid-restore, then --recover"
rc="$(CHICKADEE_DB_UPGRADE_TEST_CRASH_AT=restore upgrade --to "$NEW_MAJOR" --yes --skip-snapshot --replace-target)"
check "4: crashed" "99" "$rc"
check "4: lock left behind" "present" "$([[ -f "$CHICKADEE_COMPOSE_DIR/.db-upgrade.lock" ]] && echo present || echo absent)"
rc="$(upgrade --to "$NEW_MAJOR" --yes --skip-snapshot --replace-target)"
check "4: a new run refuses while the lock exists" "1" "$rc"
check "4: names --recover" "1" "$(grep -c -- '--recover' "$TMP/last-run.log")"
rc="$(upgrade --recover)"
check "4: --recover succeeds" "0" "$rc"
[[ "$rc" == "0" ]] || show_last_run
old_intact "4"

echo "== 5. the upgrade"
rc="$(upgrade --to "$NEW_MAJOR" --yes --skip-snapshot --replace-target)"
check "5: exit 0" "0" "$rc"
[[ "$rc" == "0" ]] || show_last_run
check "5: server is on $NEW_MAJOR" "$NEW_MAJOR" "$(major)"
check "5: data checksums on" "on" "$(q 'SHOW data_checksums')"
check "5: users carried over" "$SEED_USERS" "$(q 'SELECT count(*) FROM users')"
check "5: submissions carried over" "$SEED_SUBS" "$(q 'SELECT count(*) FROM submissions')"
check "5: migrations carried over" "3" "$(q 'SELECT count(*) FROM _fluent_migrations')"
check "5: sequence continues after the seed" "$((SEED_SEQ + 1))" "$(q "SELECT nextval('users_id_seq')")"
check "5: MCP role logs in with its old password" "150" "$(mcp 'SELECT count(*) FROM submissions')"
check "5: database setting kept" "45s" "$(mcp 'SHOW statement_timeout')"
check "5: database CONNECT grant kept (PUBLIC revoked)" "f" "$(q "SELECT has_database_privilege('public', 'chickadee', 'CONNECT')")"
check "5: trigger still fires" "t" "$(q "WITH u AS (UPDATE users SET role = role WHERE id = 1 RETURNING updated_at) SELECT updated_at IS NOT NULL FROM u")"
check "5: pg_stat_statements present" "1" "$(q "SELECT count(*) FROM pg_extension WHERE extname = 'pg_stat_statements'")"
check "5: lock removed" "absent" "$([[ -f "$CHICKADEE_COMPOSE_DIR/.db-upgrade.lock" ]] && echo present || echo absent)"
RUN_DIR="$(ls -d "$CHICKADEE_BACKUP_DIR"/db-upgrade-*-to-pg"$NEW_MAJOR" 2>/dev/null | sort | tail -n1)"
check "5: run recorded as ok" "ok" "$(cat "$RUN_DIR/result" 2>/dev/null)"
# The inventory that had to match covers what production depends on.
for line in '^role|chickadee_mcp|' '^policy|public.submissions|mcp_no_secret|' '^extension|pg_stat_statements$' \
            '^migration|AddKind|2$' '^rows|public.submissions|200$' '^dbsetting|' '^rel|public.submissions|r|chickadee|true|'; do
  check "5: inventory compared $line" "1" "$(grep -c "$line" "$RUN_DIR/inventory-before.txt" 2>/dev/null)"
done
check "5: pin file names the new image" "1" "$(grep -c "image: $CHICKADEE_DB_IMAGE_REPO:$NEW_MAJOR" "$CHICKADEE_COMPOSE_DIR/docker-compose.db.yml")"
check "5: old volume still exists" "0" "$(docker volume inspect "${PROJECT}_chickadee-postgres" >/dev/null 2>&1; echo $?)"

echo "== 6. a second run is a no-op"
rc="$(upgrade --to "$NEW_MAJOR" --yes --skip-snapshot)"
check "6: exit 0" "0" "$rc"
check "6: says already" "1" "$(grep -c 'already on PostgreSQL' "$TMP/last-run.log")"

echo "== 7. a stray recreate keeps the new version and the data"
compose up -d --no-deps --force-recreate db >/dev/null 2>&1
wait_ready
check "7: still on $NEW_MAJOR" "$NEW_MAJOR" "$(major)"
check "7: users still there" "$SEED_USERS" "$(q 'SELECT count(*) FROM users')"

echo ""
echo "$PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
