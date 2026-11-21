#!/usr/bin/env bash
# db-major-upgrade.sh — Move the Compose `db` service to a new PostgreSQL major
# version by dump and restore into a NEW volume, with a before/after inventory
# check and automatic rollback (#3148).
#
# Usage:
#   scripts/db-major-upgrade.sh --to 18 [--yes] [--skip-snapshot]
#                                [--replace-target] [--no-deployer-check]
#                                [--allow-restore-warnings]
#   scripts/db-major-upgrade.sh --to 18 --check     # preflight only, changes nothing
#   scripts/db-major-upgrade.sh --pin-current       # pin the running db, change nothing else
#   scripts/db-major-upgrade.sh --recover           # roll back an interrupted run
#
# Why dump and restore, not pg_upgrade:
#   * pg_upgrade inside Docker needs the old and new binaries in one container.
#   * New clusters (18+) have data checksums on by default and pg_upgrade
#     refuses clusters that differ. A restore gets checksums for free.
#   * Every index is rebuilt by the new server, so a libc collation change
#     between the old and new images cannot leave a silently corrupt index.
#   At Chickadee's size (hundreds of MB) the dump and restore take minutes.
#
# Which database is live is recorded in docker-compose.db.yml, beside
# docker-compose.yml. This script writes it; nobody edits it by hand.
# chickadee_compose_file_args (scripts/lib/deployment-target.sh) adds it after
# every other compose file, so it wins. It pins the image and names the volume
# EXTERNALLY by its real Docker name, so a plain `docker compose up -d` can never
# move the database to an empty volume. The old volume is never written to: a
# rollback (automatic on any failure, or --recover after a crash) points
# docker-compose.db.yml back at it.
#
# PGDATA stays /var/lib/postgresql/data on every major version. The postgres:18
# image moved its default to /var/lib/postgresql/18/docker; setting PGDATA
# explicitly is the image's documented way to keep the old layout, and it lets
# one override shape serve every version.
#
# Steps (each logged to backups/db-upgrade-<stamp>-pg<old>-to-pg<new>/upgrade.log):
#   preflight   versions, target volume free, deployer paused, disk, SCRAM-only
#               passwords, new image pulled — all before anything stops
#   snapshot    scripts/snapshot.sh --label pre-pg<new> (unless --skip-snapshot)
#   stop        every server container and the Compose runner
#   inventory   row counts, migrations, roles, grants, RLS, policies, sequences,
#               indexes, constraints, triggers, extensions, database settings
#   dump        pg_dumpall --globals-only + pg_dump -Fc, from the old server
#   switch      docker-compose.db.yml -> new image on a new volume; recreate db
#   restore     globals, then pg_restore --create; ANALYZE
#   verify      the same inventory must match exactly; checksums on
#   start       servers and runner back; /health must answer
# Any failure after `stop` rolls back to the old volume and restarts the app.
#
# The lock file .db-upgrade.lock (beside docker-compose.yml) exists only while
# the app is down. If it is present, a run was interrupted: run --recover.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/deployment-target.sh
. "$SCRIPT_DIR/lib/deployment-target.sh"

COMPOSE_DIR="${CHICKADEE_COMPOSE_DIR:-$REPO_ROOT}"
COMPOSE_FILE="${CHICKADEE_COMPOSE_FILE:-$COMPOSE_DIR/docker-compose.yml}"
DB_OVERRIDE="$COMPOSE_DIR/docker-compose.db.yml"
LOCK_FILE="$COMPOSE_DIR/.db-upgrade.lock"
BACKUP_DIR="${CHICKADEE_BACKUP_DIR:-$REPO_ROOT/backups}"
STATE_DIR="${CHICKADEE_STATE_DIR:-/var/lib/chickadee-deploy}"
DB_IMAGE_REPO="${CHICKADEE_DB_IMAGE_REPO:-postgres}"
PGDATA_PATH="/var/lib/postgresql/data"
DB_SERVICE="db"
RUNNER_SERVICE="${CHICKADEE_RUNNER_SERVICE:-runner}"
READY_TIMEOUT_SECS="${CHICKADEE_DB_READY_TIMEOUT_SECS:-180}"
HEALTH_TIMEOUT_SECS="${CHICKADEE_HEALTH_TIMEOUT_SECS:-180}"
# Test hooks (scripts/test-db-major-upgrade.sh). FAIL_AT makes the named step
# fail, which must roll back. CRASH_AT exits at the named step WITHOUT rolling
# back, as a SIGKILL would, which --recover must then repair.
TEST_FAIL_AT="${CHICKADEE_DB_UPGRADE_TEST_FAIL_AT:-}"
TEST_CRASH_AT="${CHICKADEE_DB_UPGRADE_TEST_CRASH_AT:-}"

mapfile -t COMPOSE_ARGS < <(chickadee_compose_file_args "$COMPOSE_DIR" "$COMPOSE_FILE")
compose() { docker compose --project-directory "$COMPOSE_DIR" "${COMPOSE_ARGS[@]}" "$@"; }
COMPOSE_STRING="docker compose --project-directory $COMPOSE_DIR ${COMPOSE_ARGS[*]}"

log()  { printf '%s ==> %s\n' "$(date -u +%H:%M:%S)" "$*"; }
warn() { printf '%s WARN: %s\n' "$(date -u +%H:%M:%S)" "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() { sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
MODE="upgrade"
TARGET_MAJOR=""
ASSUME_YES=0
SKIP_SNAPSHOT=0
REPLACE_TARGET=0
DEPLOYER_CHECK=1
ALLOW_RESTORE_WARNINGS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --to)                [[ $# -ge 2 ]] || die "--to needs a major version"; TARGET_MAJOR="$2"; shift 2 ;;
    --check)             MODE="check"; shift ;;
    --pin-current)       MODE="pin"; shift ;;
    --recover)           MODE="recover"; shift ;;
    --yes)               ASSUME_YES=1; shift ;;
    --skip-snapshot)     SKIP_SNAPSHOT=1; shift ;;
    --replace-target)    REPLACE_TARGET=1; shift ;;
    --no-deployer-check) DEPLOYER_CHECK=0; shift ;;
    --allow-restore-warnings) ALLOW_RESTORE_WARNINGS=1; shift ;;
    -h|--help)          usage; exit 0 ;;
    *)                   die "unknown argument: $1 (see --help)" ;;
  esac
done
if [[ "$MODE" == "upgrade" || "$MODE" == "check" ]]; then
  [[ "$TARGET_MAJOR" =~ ^[0-9]+$ ]] || die "--to <major> is required (e.g. --to 18)"
  (( TARGET_MAJOR >= 13 )) || die "--to $TARGET_MAJOR: only PostgreSQL 13 and newer are supported"
fi

# ---------------------------------------------------------------------------
# Observations
# ---------------------------------------------------------------------------
command -v docker  >/dev/null 2>&1 || die "docker is not installed"
command -v python3 >/dev/null 2>&1 || die "python3 is not installed"

# Compose's view of the stack, once.
CONFIG_JSON="$(compose config --format json)" || die "docker compose config failed in $COMPOSE_DIR"
cfg() { python3 -c "import json,sys; c=json.loads(sys.argv[1]); print(eval(sys.argv[2]))" "$CONFIG_JSON" "$1"; }
PROJECT="$(cfg 'c["name"]')"
DB_USER="$(cfg 'c["services"]["db"].get("environment",{}).get("POSTGRES_USER") or "postgres"')"
DB_NAME="$(cfg 'c["services"]["db"].get("environment",{}).get("POSTGRES_DB") or c["services"]["db"].get("environment",{}).get("POSTGRES_USER") or "postgres"')"

db_cid() { compose ps -q "$DB_SERVICE" 2>/dev/null | head -n1; }
# psql against the running db over the Unix socket. $1 = database, rest = args.
dbpsql() { local d="$1"; shift; compose exec -T "$DB_SERVICE" psql -X -v ON_ERROR_STOP=1 -U "$DB_USER" -d "$d" "$@"; }
dbq() { dbpsql "$DB_NAME" -Atc "$1"; }

running_major() { local n; n="$(dbq 'SHOW server_version_num' | tr -d '[:space:]')"; echo $(( n / 10000 )); }
# The real Docker volume mounted at PGDATA in the running db container.
running_volume() {
  docker inspect -f '{{range .Mounts}}{{if eq .Destination "'"$PGDATA_PATH"'"}}{{.Name}}{{end}}{{end}}' "$(db_cid)"
}
running_image() { docker inspect -f '{{.Config.Image}}' "$(db_cid)"; }

# Wait until the db accepts TCP connections. Over TCP, not the socket: the
# image's first-boot init runs a temporary server with listen_addresses='', and
# a socket check would pass during init and then lose the server to the restart.
wait_db_ready() {
  local waited=0
  until compose exec -T "$DB_SERVICE" pg_isready -q -h 127.0.0.1 -U "$DB_USER" >/dev/null 2>&1; do
    sleep 2; waited=$((waited + 2))
    (( waited < READY_TIMEOUT_SECS )) || return 1
  done
  # And a real query (over the socket, which needs no password), so a server
  # still finishing recovery is not "ready".
  dbpsql postgres -Atc 'SELECT 1' >/dev/null
}

# Write docker-compose.db.yml. $1 = image, $2 = real Docker volume name, $3 = note.
write_db_override() {
  local image="$1" volume="$2" note="$3" tmp
  tmp="$(mktemp "$DB_OVERRIDE.XXXXXX")"
  cat > "$tmp" <<EOF
# Written by scripts/db-major-upgrade.sh — do not edit by hand.
# $note
# Pins which PostgreSQL image and which data volume the db service uses.
# Included last by chickadee_compose_file_args, so it overrides
# docker-compose.yml. The volume is external, named by its real Docker name.
services:
  db:
    image: $image
    environment:
      PGDATA: $PGDATA_PATH
    volumes:
      - chickadee-db-active:$PGDATA_PATH
volumes:
  chickadee-db-active:
    external: true
    name: $volume
EOF
  mv "$tmp" "$DB_OVERRIDE"
  # The compose arguments are fixed at startup; the file now exists.
  mapfile -t COMPOSE_ARGS < <(chickadee_compose_file_args "$COMPOSE_DIR" "$COMPOSE_FILE")
}

# Recreate only the db container from the current compose files.
recreate_db() {
  compose stop "$DB_SERVICE" >/dev/null 2>&1 || true
  compose up -d --no-deps --force-recreate "$DB_SERVICE"
}

# Servers and the runner: exactly what was running is stopped and restarted.
start_app() {  # $1 = space-separated server names, $2 = 1 if the runner ran
  local s
  for s in $1; do docker start "$s" >/dev/null && log "started $s"; done
  if [[ "$2" == "1" ]]; then compose up -d --no-deps "$RUNNER_SERVICE" >/dev/null && log "started $RUNNER_SERVICE"; fi
  [[ -n "$1" ]] || return 0
  local target mode name port waited=0
  target="$(chickadee_server_target "$COMPOSE_STRING")"
  read -r mode name port <<<"$target"
  [[ "$mode" != "none" ]] || { warn "no live server resolved after start"; return 1; }
  until curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
    sleep 3; waited=$((waited + 3))
    (( waited < HEALTH_TIMEOUT_SECS )) || { warn "$name did not answer /health within ${HEALTH_TIMEOUT_SECS}s"; return 1; }
  done
  log "$name answers /health"
}

test_hook() {  # $1 = step name
  if [[ -n "$TEST_CRASH_AT" && "$TEST_CRASH_AT" == "$1" ]]; then
    printf 'TEST: simulated crash at %s\n' "$1" >&2
    trap - ERR EXIT
    exit 99
  fi
  if [[ -n "$TEST_FAIL_AT" && "$TEST_FAIL_AT" == "$1" ]]; then
    printf 'TEST: simulated failure at %s\n' "$1" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Inventory: everything a correct restore must reproduce exactly. Extension
# VERSIONS are left out on purpose (the new server installs its own), as are
# policy expressions (their deparsed text can change between majors).
# ---------------------------------------------------------------------------
INVENTORY_SQL="$(cat <<'SQL'
SELECT 'db|' || pg_encoding_to_char(encoding) || '|' || datcollate || '|' || datctype
       || '|' || pg_get_userbyid(datdba)
       || '|' || coalesce((SELECT string_agg(coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type,
                                             ',' ORDER BY coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC'), a.privilege_type)
                           FROM aclexplode(datacl) a), '')
  FROM pg_database WHERE datname = current_database();
SELECT 'dbsetting|' || coalesce(r.rolname, '*') || '|' || array_to_string(s.setconfig, ',')
  FROM pg_db_role_setting s
  JOIN pg_database d ON d.oid = s.setdatabase AND d.datname = current_database()
  LEFT JOIN pg_roles r ON r.oid = s.setrole
 ORDER BY 1;
SELECT 'role|' || rolname || '|' || rolsuper || '|' || rolinherit || '|' || rolcreaterole || '|'
       || rolcreatedb || '|' || rolcanlogin || '|' || rolbypassrls || '|' || rolconnlimit
       || '|' || md5(coalesce(rolpassword, ''))
  FROM pg_authid WHERE rolname !~ '^pg_' ORDER BY rolname;
SELECT 'member|' || r.rolname || '|' || m.rolname
  FROM pg_auth_members am JOIN pg_roles r ON r.oid = am.roleid JOIN pg_roles m ON m.oid = am.member
 WHERE m.rolname !~ '^pg_' ORDER BY 1;
SELECT 'schema|' || n.nspname || '|' || pg_get_userbyid(n.nspowner) || '|'
       || coalesce((SELECT string_agg(coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type,
                                      ',' ORDER BY coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC'), a.privilege_type)
                    FROM aclexplode(n.nspacl) a), '')
  FROM pg_namespace n
 WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' ORDER BY 1;
SELECT 'rel|' || n.nspname || '.' || c.relname || '|' || c.relkind || '|' || pg_get_userbyid(c.relowner)
       || '|' || c.relrowsecurity || '|' || c.relforcerowsecurity || '|'
       || coalesce((SELECT string_agg(coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type,
                                      ',' ORDER BY coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC'), a.privilege_type)
                    FROM aclexplode(c.relacl) a), '')
  FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
   AND NOT EXISTS (SELECT 1 FROM pg_depend d WHERE d.objid = c.oid AND d.deptype = 'e')
 ORDER BY 1;
SELECT 'column|' || n.nspname || '.' || c.relname || '|' || a.attname || '|'
       || format_type(a.atttypid, a.atttypmod) || '|' || a.attnotnull || '|' || a.atthasdef
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
 WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema'
   AND c.relkind IN ('r', 'p') AND a.attnum > 0 AND NOT a.attisdropped
 ORDER BY 1;
SELECT 'defacl|' || pg_get_userbyid(d.defaclrole) || '|' || coalesce(n.nspname, '*') || '|' || d.defaclobjtype || '|'
       || coalesce((SELECT string_agg(coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC') || ':' || a.privilege_type,
                                      ',' ORDER BY coalesce(nullif(a.grantee, 0)::regrole::text, 'PUBLIC'), a.privilege_type)
                    FROM aclexplode(d.defaclacl) a), '')
  FROM pg_default_acl d LEFT JOIN pg_namespace n ON n.oid = d.defaclnamespace ORDER BY 1;
SELECT 'policy|' || schemaname || '.' || tablename || '|' || policyname || '|' || permissive || '|'
       || array_to_string(roles, ',') || '|' || cmd
  FROM pg_policies ORDER BY 1;
SELECT 'index|' || schemaname || '.' || indexname || '|' || tablename
  FROM pg_indexes WHERE schemaname !~ '^pg_' AND schemaname <> 'information_schema' ORDER BY 1;
-- NOT NULL (contype 'n') is left out: 18 stores it in pg_constraint, 16 does
-- not. The column lines above compare attnotnull instead.
SELECT 'constraint|' || conrelid::regclass::text || '|' || conname || '|' || contype
  FROM pg_constraint c JOIN pg_namespace n ON n.oid = c.connamespace
 WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' AND c.contype <> 'n'
 ORDER BY 1;
SELECT 'trigger|' || tgrelid::regclass::text || '|' || tgname || '|' || tgenabled
  FROM pg_trigger WHERE NOT tgisinternal ORDER BY 1;
SELECT 'function|' || n.nspname || '.' || p.proname || '(' || pg_get_function_identity_arguments(p.oid) || ')'
  FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
  LEFT JOIN pg_depend d ON d.objid = p.oid AND d.deptype = 'e'
 WHERE n.nspname !~ '^pg_' AND n.nspname <> 'information_schema' AND d.objid IS NULL
 ORDER BY 1;
SELECT 'sequence|' || schemaname || '.' || sequencename || '|' || coalesce(last_value::text, 'unset')
  FROM pg_sequences ORDER BY 1;
SELECT 'extension|' || extname FROM pg_extension ORDER BY 1;
SELECT 'rows|' || table_schema || '.' || table_name || '|'
       || (xpath('/row/c/text()',
                 query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name), false, true, '')))[1]::text
  FROM information_schema.tables
 WHERE table_type = 'BASE TABLE' AND table_schema !~ '^pg_' AND table_schema <> 'information_schema'
 ORDER BY 1;
SQL
)"

take_inventory() {  # $1 = output file
  dbpsql "$DB_NAME" -At -c "$INVENTORY_SQL" > "$1"
  # Fluent's migration history, row by row, when this is a Chickadee database.
  if [[ "$(dbq "SELECT to_regclass('public._fluent_migrations') IS NOT NULL")" == "t" ]]; then
    dbq "SELECT 'migration|' || name || '|' || batch FROM _fluent_migrations ORDER BY name" >> "$1"
  fi
}

# ---------------------------------------------------------------------------
# Lock file: written once the app is down, removed once it is back.
# ---------------------------------------------------------------------------
write_lock() {
  python3 - "$LOCK_FILE" <<PY
import json, sys
json.dump({
    "run_dir": "$RUN_DIR",
    "old_image": "$OLD_IMAGE",
    "old_volume": "$OLD_VOLUME",
    "old_major": $OLD_MAJOR,
    "target_major": $TARGET_MAJOR,
    "target_volume": "$TARGET_VOLUME",
    "servers": "$STOPPED_SERVERS",
    "runner_was_running": $RUNNER_WAS_RUNNING,
}, open(sys.argv[1], "w"), indent=2)
PY
}
lock_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])' "$LOCK_FILE" "$1"; }

# ---------------------------------------------------------------------------
# Rollback: back to the old image on the old (never-written) volume.
# ---------------------------------------------------------------------------
rollback() {  # uses OLD_IMAGE OLD_VOLUME OLD_MAJOR STOPPED_SERVERS RUNNER_WAS_RUNNING
  set +e
  trap - ERR
  warn "rolling back to $OLD_IMAGE on volume $OLD_VOLUME"
  local s
  for s in $STOPPED_SERVERS; do docker stop "$s" >/dev/null 2>&1; done
  write_db_override "$OLD_IMAGE" "$OLD_VOLUME" "Rolled back from a failed upgrade to $TARGET_MAJOR at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  if ! recreate_db || ! wait_db_ready; then
    warn "the old database did not come back. The lock file stays; fix the db service by hand, then run --recover."
    return 1
  fi
  local back; back="$(running_major)"
  if [[ "$back" != "$OLD_MAJOR" ]]; then
    warn "after rollback the server reports major $back, expected $OLD_MAJOR. The lock file stays."
    return 1
  fi
  if ! start_app "$STOPPED_SERVERS" "$RUNNER_WAS_RUNNING"; then
    warn "the database is back on $OLD_MAJOR but the app did not come back healthy. Check the server logs."
    rm -f "$LOCK_FILE"
    return 1
  fi
  rm -f "$LOCK_FILE"
  warn "rolled back: PostgreSQL $OLD_MAJOR on $OLD_VOLUME, app running. The new volume $TARGET_VOLUME is left for inspection (re-run with --replace-target)."
  return 0
}

on_error() {
  local line="$1"
  trap - ERR
  warn "step '$STEP' failed (line $line)."
  if [[ "${ARMED:-0}" == "1" ]]; then
    rollback || true
  fi
  [[ -n "${RUN_DIR:-}" ]] && printf 'failed at %s\n' "$STEP" > "$RUN_DIR/result" 2>/dev/null
  exit 1
}

# ---------------------------------------------------------------------------
# --recover
# ---------------------------------------------------------------------------
if [[ "$MODE" == "recover" ]]; then
  [[ -f "$LOCK_FILE" ]] || die "no interrupted run: $LOCK_FILE does not exist"
  RUN_DIR="$(lock_field run_dir)"
  OLD_IMAGE="$(lock_field old_image)"
  OLD_VOLUME="$(lock_field old_volume)"
  OLD_MAJOR="$(lock_field old_major)"
  TARGET_MAJOR="$(lock_field target_major)"
  TARGET_VOLUME="$(lock_field target_volume)"
  STOPPED_SERVERS="$(lock_field servers)"
  RUNNER_WAS_RUNNING="$(lock_field runner_was_running)"
  [[ "$RUNNER_WAS_RUNNING" == "True" ]] && RUNNER_WAS_RUNNING=1
  [[ "$RUNNER_WAS_RUNNING" == "False" ]] && RUNNER_WAS_RUNNING=0
  log "recovering the interrupted upgrade recorded in $LOCK_FILE ($RUN_DIR)"
  if rollback; then
    printf 'recovered (rolled back)\n' > "$RUN_DIR/result" 2>/dev/null || true
    exit 0
  fi
  exit 1
fi

[[ ! -f "$LOCK_FILE" ]] || die "an earlier run was interrupted ($LOCK_FILE exists). Run: $0 --recover"

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
[[ -n "$(db_cid)" ]] || die "the db service is not running in $COMPOSE_DIR"
OLD_MAJOR="$(running_major)"
OLD_IMAGE="$(running_image)"
OLD_VOLUME="$(running_volume)"
[[ -n "$OLD_VOLUME" ]] || die "the running db container has no volume mounted at $PGDATA_PATH"

if [[ "$MODE" == "pin" ]]; then
  write_db_override "$OLD_IMAGE" "$OLD_VOLUME" "Pinned to the running database (PostgreSQL $OLD_MAJOR) at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
  log "pinned: $DB_OVERRIDE -> $OLD_IMAGE on $OLD_VOLUME (nothing was restarted)"
  exit 0
fi

if [[ "$OLD_MAJOR" == "$TARGET_MAJOR" ]]; then
  log "already on PostgreSQL $TARGET_MAJOR ($OLD_IMAGE on $OLD_VOLUME); nothing to do"
  exit 0
fi
(( TARGET_MAJOR > OLD_MAJOR )) || die "refusing to go from $OLD_MAJOR down to $TARGET_MAJOR"

TARGET_IMAGE="$DB_IMAGE_REPO:$TARGET_MAJOR"
TARGET_VOLUME="${PROJECT}_chickadee-postgres-${TARGET_MAJOR}"
[[ "$TARGET_VOLUME" != "$OLD_VOLUME" ]] || die "the target volume $TARGET_VOLUME is the live one"

PROBLEMS=()
if docker volume inspect "$TARGET_VOLUME" >/dev/null 2>&1; then
  if (( REPLACE_TARGET )) && [[ "$MODE" == "check" ]]; then
    log "the leftover target volume $TARGET_VOLUME would be removed (--replace-target)"
  elif (( REPLACE_TARGET )); then
    docker volume rm "$TARGET_VOLUME" >/dev/null || die "could not remove $TARGET_VOLUME (is a container using it?)"
    log "removed the leftover target volume $TARGET_VOLUME (--replace-target)"
  else
    PROBLEMS+=("the target volume $TARGET_VOLUME already exists (a failed earlier attempt?). Inspect it, then re-run with --replace-target.")
  fi
fi

if (( DEPLOYER_CHECK )) && [[ -d "$STATE_DIR" ]] && [[ ! -f "$STATE_DIR/paused" ]]; then
  PROBLEMS+=("the deploy daemon is not paused ($STATE_DIR/paused is absent). Pause it on the admin Deployment page first, or pass --no-deployer-check.")
fi

MD5_ROLES="$(dbq "SELECT string_agg(rolname, ', ') FROM pg_authid WHERE rolpassword LIKE 'md5%'")"
if [[ -n "$MD5_ROLES" ]]; then
  PROBLEMS+=("roles with MD5 password hashes: $MD5_ROLES. The new image authenticates with scram-sha-256, so they could not log in. Reset their passwords (SET password_encryption = 'scram-sha-256'; ALTER ROLE ... PASSWORD ...) first.")
fi

DB_BYTES="$(dbq "SELECT pg_database_size(current_database())" | tr -d '[:space:]')"
NEED_KIB=$(( DB_BYTES * 3 / 1024 ))
DOCKER_ROOT="$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || true)"
mkdir -p "$BACKUP_DIR"
for path in "$BACKUP_DIR" "$DOCKER_ROOT"; do
  [[ -n "$path" && -d "$path" ]] || continue
  free_kib="$(df -Pk "$path" | awk 'NR==2 {print $4}')"
  if (( free_kib < NEED_KIB )); then
    PROBLEMS+=("$path has $((free_kib / 1024)) MB free; the upgrade needs about $((NEED_KIB / 1024)) MB (3x the database).")
  fi
done

STOPPED_SERVERS="$(chickadee_all_running_servers "$COMPOSE_STRING" | tr '\n' ' ' | sed 's/ *$//')"
RUNNER_WAS_RUNNING=0
if [[ -n "$(compose ps -q --status running "$RUNNER_SERVICE" 2>/dev/null)" ]]; then RUNNER_WAS_RUNNING=1; fi

cat <<EOF

================================================================
  Chickadee PostgreSQL major upgrade
================================================================
  Compose project:   $PROJECT ($COMPOSE_DIR)
  Database:          $DB_NAME (owner role $DB_USER), $((DB_BYTES / 1024 / 1024)) MB
  From:              PostgreSQL $OLD_MAJOR  $OLD_IMAGE  on $OLD_VOLUME
  To:                PostgreSQL $TARGET_MAJOR  $TARGET_IMAGE  on $TARGET_VOLUME (new)
  Servers to stop:   ${STOPPED_SERVERS:-(none running)}
  Runner to stop:    $([[ $RUNNER_WAS_RUNNING == 1 ]] && echo "$RUNNER_SERVICE" || echo "(not running)")
  Snapshot first:    $([[ $SKIP_SNAPSHOT == 1 ]] && echo no || echo "yes (pre-pg$TARGET_MAJOR)")
  Old volume:        kept untouched; rollback target
EOF

if (( ${#PROBLEMS[@]} )); then
  echo ""
  for p in "${PROBLEMS[@]}"; do echo "  BLOCKED: $p"; done
  echo ""
  die "preflight failed; nothing was changed"
fi

log "pulling $TARGET_IMAGE (before anything stops)"
docker pull -q "$TARGET_IMAGE" >/dev/null || die "could not pull $TARGET_IMAGE"

if [[ "$MODE" == "check" ]]; then
  log "preflight passed; --check changes nothing"
  exit 0
fi

if (( ! ASSUME_YES )); then
  echo ""
  echo "The app is down from 'stop' to 'start' (a few minutes at this size)."
  read -r -p "Type UPGRADE to proceed: " CONFIRM
  [[ "$CONFIRM" == "UPGRADE" ]] || die "aborted; nothing was changed"
fi

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
STAMP="$(date -u +%Y%m%d-%H%M%S)"
RUN_DIR="$BACKUP_DIR/db-upgrade-$STAMP-pg$OLD_MAJOR-to-pg$TARGET_MAJOR"
mkdir -p "$RUN_DIR"
exec > >(tee -a "$RUN_DIR/upgrade.log") 2>&1
TEE_PID=$!
# Let tee finish writing before the script's exit is reported.
trap 'exec 1>&- 2>&-; wait "$TEE_PID" 2>/dev/null' EXIT
log "run directory: $RUN_DIR"

STEP="snapshot"
ARMED=0
trap 'on_error $LINENO' ERR

if (( ! SKIP_SNAPSHOT )); then
  log "taking a snapshot (scripts/snapshot.sh --label pre-pg$TARGET_MAJOR)"
  "$REPO_ROOT/scripts/snapshot.sh" --label "pre-pg$TARGET_MAJOR"
fi

STEP="stop"
write_lock
ARMED=1
for s in $STOPPED_SERVERS; do log "stopping $s"; docker stop "$s" >/dev/null; done
if (( RUNNER_WAS_RUNNING )); then log "stopping $RUNNER_SERVICE"; compose stop "$RUNNER_SERVICE" >/dev/null; fi
test_hook stop

STEP="inventory"
log "inventory of the old database"
take_inventory "$RUN_DIR/inventory-before.txt"
log "  $(grep -c '^rows|' "$RUN_DIR/inventory-before.txt") tables, $(grep -c '^role|' "$RUN_DIR/inventory-before.txt") roles"
test_hook inventory

STEP="dump"
log "dumping roles (pg_dumpall --globals-only) and $DB_NAME (pg_dump -Fc)"
compose exec -T "$DB_SERVICE" pg_dumpall -U "$DB_USER" --globals-only > "$RUN_DIR/globals.sql"
compose exec -T "$DB_SERVICE" pg_dump -U "$DB_USER" -Fc "$DB_NAME" > "$RUN_DIR/database.dump"
[[ -s "$RUN_DIR/database.dump" ]] || { warn "the dump is empty"; false; }
log "  dump: $(( $(wc -c < "$RUN_DIR/database.dump") / 1024 )) KB"
test_hook dump

STEP="switch"
log "creating $TARGET_VOLUME and switching db to $TARGET_IMAGE"
docker volume create --label "chickadee.db-major=$TARGET_MAJOR" "$TARGET_VOLUME" >/dev/null
write_db_override "$TARGET_IMAGE" "$TARGET_VOLUME" "PostgreSQL $TARGET_MAJOR, upgraded from $OLD_MAJOR ($OLD_VOLUME) at $(date -u +%Y-%m-%dT%H:%M:%SZ)."
recreate_db
wait_db_ready || { warn "PostgreSQL $TARGET_MAJOR did not become ready in ${READY_TIMEOUT_SECS}s"; false; }
NEW_MAJOR="$(running_major)"
[[ "$NEW_MAJOR" == "$TARGET_MAJOR" ]] || { warn "the new server reports major $NEW_MAJOR"; false; }
log "  PostgreSQL $(dbq 'SHOW server_version') is up; data checksums: $(dbq 'SHOW data_checksums')"
test_hook switch

STEP="restore"
log "restoring roles"
# The image already created the bootstrap role; every other line applies as is,
# including the bootstrap role's ALTER (which carries its old password hash).
python3 - "$DB_USER" "$RUN_DIR/globals.sql" > "$RUN_DIR/globals-apply.sql" <<'PY'
import re, sys
user = sys.argv[1]
pattern = re.compile(r'^CREATE ROLE ("?)' + re.escape(user) + r'\1;$')
for line in open(sys.argv[2]):
    if pattern.match(line.rstrip("\n")):
        continue
    sys.stdout.write(line)
PY
dbpsql postgres -q < "$RUN_DIR/globals-apply.sql" >/dev/null
log "restoring $DB_NAME (pg_restore --create)"
# The image created an empty $DB_NAME at first boot. Drop it so pg_restore
# --create recreates it from the dump with the original encoding, locale,
# database-level grants and settings, which a plain restore leaves out.
dbpsql postgres -qc "DROP DATABASE \"$DB_NAME\""
set +e
compose exec -T "$DB_SERVICE" pg_restore -U "$DB_USER" --create -d postgres \
  < "$RUN_DIR/database.dump" 2> "$RUN_DIR/pg_restore.stderr"
rc=$?
set -e
if (( rc != 0 )); then
  # Into a fresh cluster with every role already present, a clean restore
  # reports nothing. Any error is a reason to stop and look, not to continue.
  warn "pg_restore exited $rc; first lines of $RUN_DIR/pg_restore.stderr:"
  head -n 10 "$RUN_DIR/pg_restore.stderr" >&2
  if (( rc == 1 && ALLOW_RESTORE_WARNINGS )); then
    warn "continuing (--allow-restore-warnings); the inventory check below decides"
  else
    false
  fi
fi
log "ANALYZE (planner statistics are not carried in a dump)"
dbq "ANALYZE" >/dev/null
test_hook restore

STEP="verify"
log "inventory of the new database"
take_inventory "$RUN_DIR/inventory-after.txt"
if ! diff -u "$RUN_DIR/inventory-before.txt" "$RUN_DIR/inventory-after.txt" > "$RUN_DIR/inventory.diff"; then
  warn "the new database does not match the old one:"
  head -n 40 "$RUN_DIR/inventory.diff" >&2
  false
fi
log "  inventory matches ($(wc -l < "$RUN_DIR/inventory-after.txt" | tr -d ' ') lines)"
test_hook verify

STEP="start"
start_app "$STOPPED_SERVERS" "$RUNNER_WAS_RUNNING"
test_hook start

ARMED=0
trap - ERR
rm -f "$LOCK_FILE"
printf 'ok\n' > "$RUN_DIR/result"

cat <<EOF

==> Done: PostgreSQL $OLD_MAJOR -> $TARGET_MAJOR.
    Live:      $TARGET_IMAGE on $TARGET_VOLUME  (pinned in $DB_OVERRIDE)
    Kept:      $OLD_VOLUME (PostgreSQL $OLD_MAJOR, untouched)
    Run files: $RUN_DIR

    To go back to $OLD_MAJOR (writes made since the switch are lost): stop the
    app, point docker-compose.db.yml at image $OLD_IMAGE and volume
    $OLD_VOLUME, run docker compose up -d --no-deps --force-recreate db, and
    start the app. deploy/README.md, "PostgreSQL major upgrade", has the steps.

    After two quiet weeks, delete the old volume:
      docker volume rm $OLD_VOLUME
EOF
