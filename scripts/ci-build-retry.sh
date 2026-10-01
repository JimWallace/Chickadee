#!/usr/bin/env bash
# scripts/ci-build-retry.sh
#
# Runs `swift build --build-tests` for the CI build job, and runs it ONCE MORE
# only when the first attempt died with the Family 7 signature: SwiftPM 6.4's
# default Swift Build engine crashing in libdispatch's manager thread as
# planning starts (exit 139, `_dispatch_event_loop_drain` in the backtrace).
# That crash is upstream (swiftlang/swift-build#1786) and happens before any
# compile, so a retry repeats only the manifest load and planning. Any other
# exit, including a 139 without the signature, fails the step on the first
# attempt. See docs/ci-flakiness.md, Family 7.
#
#   scripts/ci-build-retry.sh              run the build with the one retry
#   scripts/ci-build-retry.sh --self-test  prove the gate with a stub `swift`
#
# No new environment variable is read. The self-test puts a stub `swift` on
# PATH, which is also how a local check of the gate works.

set -uo pipefail

readonly signature='_dispatch_event_loop_drain'
readonly crash_status=139

attempt() {
  local log="$1"
  swift build --build-tests 2>&1 | tee "$log"
  return "${PIPESTATUS[0]}"
}

run_build() {
  local log status
  log="$(mktemp)"
  attempt "$log"
  status=$?
  if [ "$status" -eq "$crash_status" ] && grep -q -- "$signature" "$log"; then
    echo "::warning title=Family 7 retry::swift build died in libdispatch as planning started (docs/ci-flakiness.md, Family 7). Retrying once."
    attempt "$log"
    status=$?
  fi
  rm -f "$log"
  return "$status"
}

# --- self-test ---------------------------------------------------------------
# A stub `swift` that behaves per a mode file and counts its invocations.

self_test() {
  local tmp stub counter mode out status failures=0
  tmp="$(mktemp -d)"
  stub="$tmp/bin"
  counter="$tmp/count"
  mode="$tmp/mode"
  mkdir -p "$stub"
  cat > "$stub/swift" <<STUB
#!/usr/bin/env bash
n=\$(( \$(cat "$counter" 2>/dev/null || echo 0) + 1 ))
echo "\$n" > "$counter"
case "\$(cat "$mode")" in
  ok)
    echo "Build complete!"; exit 0 ;;
  compile-error)
    echo "error: cannot find 'x' in scope"; exit 1 ;;
  crash-other)
    echo "Segmentation fault (core dumped)"; exit 139 ;;
  crash-signature-once)
    if [ "\$n" -eq 1 ]; then
      echo "[Planning 1 / 3660]"
      echo "Thread 2 \"DispatchWorker\" crashed:"
      echo "0      0x00007f _dispatch_event_loop_drain + 1130 in libdispatch.so"
      echo "Segmentation fault (core dumped)"; exit 139
    fi
    echo "Build complete!"; exit 0 ;;
  crash-signature-always)
    echo "0      0x00007f _dispatch_event_loop_drain + 1130 in libdispatch.so"
    echo "Segmentation fault (core dumped)"; exit 139 ;;
esac
STUB
  chmod +x "$stub/swift"

  check() {
    local name="$1" want_status="$2" want_runs="$3" want_warning="$4"
    echo "$name" > "$mode"
    echo 0 > "$counter"
    out="$(PATH="$stub:$PATH" run_build 2>&1)"
    status=$?
    local runs warned=no
    runs="$(cat "$counter")"
    if grep -q "::warning title=Family 7 retry::" <<< "$out"; then warned=yes; fi
    if [ "$status" -ne "$want_status" ] || [ "$runs" -ne "$want_runs" ] || [ "$warned" != "$want_warning" ]; then
      echo "FAIL $name: status=$status (want $want_status) runs=$runs (want $want_runs) warning=$warned (want $want_warning)"
      failures=$((failures + 1))
    else
      echo "ok   $name: status=$status runs=$runs warning=$warned"
    fi
  }

  check ok 0 1 no
  check compile-error 1 1 no
  check crash-other 139 1 no
  check crash-signature-once 0 2 yes
  check crash-signature-always 139 2 yes

  rm -rf "$tmp"
  if [ "$failures" -ne 0 ]; then
    echo "ci-build-retry self-test: $failures failure(s)"
    return 1
  fi
  echo "ci-build-retry self-test: OK"
}

case "${1:-}" in
  --self-test) self_test ;;
  "") run_build ;;
  *) echo "usage: $0 [--self-test]" >&2; exit 2 ;;
esac
