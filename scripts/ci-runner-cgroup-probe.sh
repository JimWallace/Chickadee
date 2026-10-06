#!/bin/sh
# ci-runner-cgroup-probe.sh — checks, inside the runner container, what
# deploy/runner-entrypoint.sh promises. docker-build.yml runs it through the
# pre-step, with the Compose runner service's own user, capabilities and
# security options:
#
#   docker compose run --rm --no-deps -v <this file>:/probe.sh:ro runner \
#     "exec /app/runner-entrypoint.sh /bin/sh /probe.sh"
#
# It checks that the command runs as uid 999 with no capability, in
# /sandbox/runner; that it can create a job cgroup with memory and pids limits
# and cannot change the limits above it; that a process in a user namespace,
# as a sandboxed job runs, can move itself into the job cgroup; and that the
# job's memory limit stops the job alone.
#
# It prints one line per check and exits 1 when any check fails.

JOBS=/sys/fs/cgroup/sandbox/jobs
JOB="$JOBS/ci-probe"
FAILURES=0

pass() { echo "ok:   $*"; }
fail() { echo "FAIL: $*"; FAILURES=$((FAILURES + 1)); }

uid="$(id -u)"
[ "$uid" = "999" ] && pass "runs as uid 999" || fail "runs as uid $uid, expected 999"

caps="$(grep -E '^Cap(Inh|Prm|Eff|Bnd|Amb):' /proc/self/status)"
if [ "$(echo "$caps" | grep -c '0000000000000000$')" = "5" ]; then
  pass "holds no capability"
else
  fail "holds a capability: $caps"
fi

cgroup="$(cat /proc/self/cgroup)"
[ "$cgroup" = "0::/sandbox/runner" ] && pass "runs in /sandbox/runner" || fail "runs in $cgroup"

controllers="$(cat "$JOBS/cgroup.subtree_control" 2>/dev/null)"
if echo "$controllers" | grep -qw memory && echo "$controllers" | grep -qw pids; then
  pass "memory and pids are enabled for the jobs"
else
  fail "the jobs subtree enables only: $controllers"
fi

# A JVM reads a cgroup only when cpu, cpuset and memory are all in its
# cgroup.controllers. The pre-step enables cpu and cpuset when the container
# has them, and a GitHub runner's container has them.
for controller in cpu cpuset; do
  if ! grep -qw "$controller" /sys/fs/cgroup/cgroup.controllers; then
    pass "the container has no $controller controller to give the jobs"
  elif echo "$controllers" | grep -qw "$controller"; then
    pass "$controller is enabled for the jobs"
  else
    fail "the container has $controller, but the jobs subtree does not enable it"
  fi
done

# Without swap at 0, the job would swap and not be killed. The file exists
# only when the kernel accounts swap.
if mkdir "$JOB" 2>/dev/null \
  && echo 64M > "$JOB/memory.max" 2>/dev/null \
  && { [ ! -f "$JOB/memory.swap.max" ] || echo 0 > "$JOB/memory.swap.max"; } 2>/dev/null \
  && echo 16 > "$JOB/pids.max" 2>/dev/null; then
  pass "creates a job cgroup with memory and pids limits"
else
  fail "could not create a job cgroup with limits"
fi

for file in /sys/fs/cgroup/sandbox/memory.max "$JOBS/memory.max" "$JOBS/pids.max"; do
  if { echo 1G > "$file"; } 2>/dev/null; then
    fail "could change $file"
  else
    pass "cannot change $file"
  fi
done

# A sandboxed job is root in its own user namespace, mapped to uid 999. It
# joins its cgroup from inside that namespace.
joined="$(unshare --user --map-root-user /bin/sh -c "echo \$\$ > $JOB/cgroup.procs && cat /proc/self/cgroup" 2>&1)"
[ "$joined" = "0::/sandbox/jobs/ci-probe" ] && pass "a user-namespace process joins the job cgroup" \
  || fail "a user-namespace process could not join the job cgroup: $joined"

# 200 MB in a job limited to 64 MB: the kernel kills the job, and this script,
# outside the job cgroup, continues. The bytes are written, because zero pages
# that nothing writes are not charged.
/bin/sh -c "echo \$\$ > $JOB/cgroup.procs && exec python3 -c 'x = b\"x\" * (200 * 1024 * 1024)'" >/dev/null 2>&1
status=$?
oom_kills="$(grep '^oom_kill ' "$JOB/memory.events" 2>/dev/null | cut -d' ' -f2)"
if [ "$status" = "137" ] && [ "${oom_kills:-0}" -ge 1 ]; then
  pass "the memory limit kills the job alone (exit 137, oom_kill $oom_kills)"
else
  fail "the memory limit did not stop the job (exit $status, oom_kill ${oom_kills:-none})"
fi

rmdir "$JOB" 2>/dev/null || fail "could not remove the job cgroup"

# A JVM in a job cgroup must size itself from the job's limit, not from the
# host. JDK 25 turns off its container support when cpu or cpuset is missing
# from the cgroup.controllers it reads, and then reports the host's memory.
# Like the sandbox prelude, this joins the job cgroup from a user and mount
# namespace and binds the job cgroup over /sys/fs/cgroup, so the JVM reads
# the job's own cgroup.controllers, not the container's.
JVM_JOB="$JOBS/ci-probe-jvm"
if mkdir "$JVM_JOB" 2>/dev/null && echo 512M > "$JVM_JOB/memory.max" 2>/dev/null; then
  limit="$(unshare --user --map-root-user --mount /bin/sh -c \
    "echo \$\$ > $JVM_JOB/cgroup.procs && mount --bind $JVM_JOB /sys/fs/cgroup && exec java -XshowSettings:system -version" 2>&1 \
    | sed -n 's/^ *Memory Limit: *//p')"
  [ "$limit" = "512.00M" ] && pass "a JVM in a job cgroup sees its memory limit ($limit)" \
    || fail "a JVM in a job cgroup reports the memory limit '$limit', expected 512.00M"
  rmdir "$JVM_JOB" 2>/dev/null || fail "could not remove the JVM job cgroup"
else
  fail "could not create a job cgroup for the JVM check"
fi

if [ "$FAILURES" -gt 0 ]; then
  echo "$FAILURES check(s) failed"
  exit 1
fi
echo "all checks passed"
