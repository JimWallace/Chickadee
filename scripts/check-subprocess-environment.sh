#!/usr/bin/env bash
set -uo pipefail

# Every child the server launches gets an explicit environment.
#
# The server process holds secrets (the runner shared secret, database
# credentials, the OIDC client secret, BrightSpace keys), and swift-subprocess
# defaults to inheriting the parent's environment. So every `Subprocess.run(`
# under Sources/APIServer must pass `environment:`; `SubprocessEnvironment.swift`
# is the one bridge that builds it. `gzip` was the unguarded exception for the
# life of the GitHub tarball reader (#1797): trusted, so drift rather than
# exposure, but nothing enforced the rule the way no-foundation-process.sh
# enforces its neighbour.
#
# Each call is read from `Subprocess.run(` to its matching close paren, so a
# multi-line call is one unit and an `environment:` on any line of it counts.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

python3 - <<'PY'
import pathlib, sys

root = pathlib.Path("Sources/APIServer")
missing = []
calls = 0
for path in sorted(root.rglob("*.swift")):
    text = path.read_text(encoding="utf-8")
    start = 0
    while True:
        at = text.find("Subprocess.run(", start)
        if at < 0:
            break
        # Walk to the matching close paren of the call.
        depth = 0
        i = at + len("Subprocess.run")
        end = None
        while i < len(text):
            ch = text[i]
            if ch == "(":
                depth += 1
            elif ch == ")":
                depth -= 1
                if depth == 0:
                    end = i
                    break
            i += 1
        if end is None:
            end = len(text)
        calls += 1
        call = text[at:end]
        if "environment:" not in call:
            line = text.count("\n", 0, at) + 1
            missing.append(f"{path}:{line}")
        start = end
if calls == 0:
    print("check-subprocess-environment: found no Subprocess.run call under Sources/APIServer", file=sys.stderr)
    sys.exit(1)
if missing:
    print("check-subprocess-environment: Subprocess.run call(s) with no environment: argument", file=sys.stderr)
    for site in missing:
        print(f"  {site}", file=sys.stderr)
    print("  Pass Subprocess::Environment.only(...) (SubprocessEnvironment.swift); the default inherits the server's secrets.", file=sys.stderr)
    sys.exit(1)
print(f"check-subprocess-environment: OK ({calls} calls, every one passes environment:)")
PY
