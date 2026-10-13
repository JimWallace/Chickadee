#!/usr/bin/env bash
set -euo pipefail

# Keep Sources/ free of the Vapor 4 shapes that Vapor 5 removes.
#
# Vapor 5 is async only. It has no `EventLoopFuture`, no event loops and no
# `application.threadPool`, and its body decodes are async. Chickadee reached
# zero uses of the first three, and routes every body decode through two
# helpers, so that the move to Vapor 5 changes a few files and not
# a few hundred (docs/vapor-5-migration.md). Without this guard each new use
# would come back one review at a time, because every one of them compiles on
# Vapor 4.
#
# The rules:
#
#   1. No event-loop API: `EventLoopFuture`, `EventLoopPromise`, a succeeded or
#      failed future, `eventLoop`, `eventLoopGroup` or `.threadPool`. Use
#      async/await, and `runBlocking` (Helpers/BlockingWork.swift) for blocking
#      work.
#   2. No direct `content.decode`, on any receiver. Call
#      `decodeContent(T.self)`: on a request it is in
#      Helpers/Request+DecodeContent.swift, and on a client response it is in
#      Helpers/ClientResponse+Body.swift. Those two files are the only places
#      that change when the decode becomes async.
#
# A line that starts with `//` is not read, so the documentation of a rule
# cannot trip it. A comment after code on the same line is read. That can only
# fail the build, never hide a use.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

# Prints file:line:text for each code line under Sources/ that matches $1,
# leaving out comment lines and the files named after it (literal paths).
code_matches() {
  local pattern="$1"
  shift
  local hits
  hits=$(grep -rnE "$pattern" Sources/ --include='*.swift' 2>/dev/null \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*//' || true)
  for allowed in "$@"; do
    hits=$(printf '%s\n' "$hits" | grep -vF "$allowed:" || true)
  done
  printf '%s\n' "$hits" | sed '/^$/d' | sort
}

status=0

event_loop=$(code_matches \
  '\bEventLoop(Future|Promise)\b|make(Succeeded|Failed)Future|\beventLoop(Group)?\b|\.threadPool\b')
if [ -n "$event_loop" ]; then
  echo "ERROR: event-loop API in Sources/ (Vapor 5 removes it)."
  echo
  echo "$event_loop" | sed 's/^/  /'
  echo
  echo "Write it with async/await. For blocking work, call runBlocking"
  echo "(Sources/APIServer/Helpers/BlockingWork.swift)."
  echo
  status=1
fi

direct_decode=$(code_matches '\bcontent\.decode\(' \
  'Sources/APIServer/Helpers/Request+DecodeContent.swift' \
  'Sources/APIServer/Helpers/ClientResponse+Body.swift')
if [ -n "$direct_decode" ]; then
  echo "ERROR: a body is decoded directly (Vapor 5 makes this async)."
  echo
  echo "$direct_decode" | sed 's/^/  /'
  echo
  echo "Call try await decodeContent(T.self) instead (Request+DecodeContent.swift"
  echo "or ClientResponse+Body.swift in Sources/APIServer/Helpers/)."
  echo
  status=1
fi

if [ "$status" -ne 0 ]; then
  exit "$status"
fi

decodes=$(grep -rcE '\.decodeContent\(' Sources/ --include='*.swift' 2>/dev/null \
  | awk -F: '{ total += $2 } END { print total + 0 }')
echo "check-vapor5-readiness: OK (no event-loop API; $decodes body decode(s) through decodeContent)"
