#!/bin/sh
# runner-entrypoint.sh — the runner container's start.
#
# The runner gives each job its own cgroup, so that one job's memory and
# processes have a hard limit that the jobs beside it do not share. Docker
# mounts /sys/fs/cgroup read-only and gives the container's cgroup to root, so
# a runner that starts as uid 999 cannot create a cgroup. This script runs
# first, as root, with only the capabilities that the steps below need
# (SYS_ADMIN, CHOWN, SETUID, SETGID, SETPCAP; see docker-compose.yml):
#
#   1. It remounts /sys/fs/cgroup read-write.
#   2. It creates /sandbox/runner and /sandbox/jobs in the container's cgroup
#      and moves itself into /sandbox/runner. A cgroup that gives controllers
#      to its children must hold no process of its own.
#   3. It enables the memory and pids controllers down to /sandbox/jobs.
#   4. It gives /sandbox to uid 999, as the kernel's delegation rules say: the
#      directories and their cgroup.procs, cgroup.threads and
#      cgroup.subtree_control files. The runner can then create a cgroup per
#      job under /sandbox/jobs and move a job's processes into it, and it
#      cannot change the limits of /sandbox itself.
#   5. It starts the command as uid 999, with no capability, an empty bounding
#      set and no_new_privs. That is the runner as it ran before this script.
#
# When a step fails (a cgroup v1 host, a missing controller, a container
# started without the capabilities), it prints why and starts the command as
# uid 999 all the same. The runner then grades without job cgroups and says so
# at startup. When the script does not run as root, it starts the command
# unchanged.
#
# Usage: runner-entrypoint.sh <command> [arguments...]

set -eu

CGROUP=/sys/fs/cgroup
SANDBOX="$CGROUP/sandbox"
RUNNER_UID=999

say() { echo "[runner-entrypoint] $*"; }

# Succeeds when the delegation is in place, or sets REASON and fails. It runs
# in this shell, not in a subshell: `$(delegate)` would leave the subshell in
# the container's root cgroup, and the root then could not give controllers to
# its children.
REASON=""
delegate() {
  if [ ! -f "$CGROUP/cgroup.controllers" ]; then
    REASON="the host does not use cgroup v2"
    return 1
  fi
  for controller in memory pids; do
    if ! grep -qw "$controller" "$CGROUP/cgroup.controllers"; then
      REASON="the $controller controller is not available to the container"
      return 1
    fi
  done
  if ! mount -o remount,rw "$CGROUP" 2>/dev/null; then
    REASON="could not remount $CGROUP read-write (the container needs CAP_SYS_ADMIN)"
    return 1
  fi
  if ! mkdir -p "$SANDBOX/runner" "$SANDBOX/jobs" 2>/dev/null \
    || ! echo "$$" > "$SANDBOX/runner/cgroup.procs" 2>/dev/null; then
    REASON="could not create $SANDBOX"
    return 1
  fi
  for parent in "$CGROUP" "$SANDBOX" "$SANDBOX/jobs"; do
    if ! echo "+memory +pids" > "$parent/cgroup.subtree_control" 2>/dev/null; then
      REASON="could not enable memory and pids in $parent"
      return 1
    fi
  done
  for directory in "$SANDBOX" "$SANDBOX/runner" "$SANDBOX/jobs"; do
    if ! chown "$RUNNER_UID:$RUNNER_UID" "$directory" "$directory/cgroup.procs" \
      "$directory/cgroup.threads" "$directory/cgroup.subtree_control" 2>/dev/null; then
      REASON="could not give $directory to uid $RUNNER_UID"
      return 1
    fi
  done
}

if [ "$#" -eq 0 ]; then
  say "usage: $0 <command> [arguments...]"
  exit 2
fi

if [ "$(id -u)" != "0" ]; then
  exec "$@"
fi

if delegate; then
  say "job cgroups delegated at /sandbox/jobs"
else
  say "job cgroups unavailable: $REASON"
fi

export HOME=/home/chickadee USER=chickadee LOGNAME=chickadee
exec setpriv --reuid="$RUNNER_UID" --regid="$RUNNER_UID" --clear-groups \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs \
  -- "$@"
