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
#
# Pure grep/sed/awk: the format-lint container has no python3.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

report="$(find Sources/APIServer -name '*.swift' -print0 | sort -z | xargs -0 awk '
function scan(path, text,    at, start, i, depth, end, call, ch, before, line) {
    start = 1
    while ((at = index(substr(text, start), "Subprocess.run(")) > 0) {
        at += start - 1
        depth = 0
        end = 0
        for (i = at + length("Subprocess.run"); i <= length(text); i++) {
            ch = substr(text, i, 1)
            if (ch == "(") {
                depth++
            } else if (ch == ")") {
                depth--
                if (depth == 0) {
                    end = i
                    break
                }
            }
        }
        if (end == 0) end = length(text)
        calls++
        call = substr(text, at, end - at + 1)
        if (index(call, "environment:") == 0) {
            before = substr(text, 1, at)
            line = gsub(/\n/, "", before) + 1
            printf "MISSING %s:%d\n", path, line
        }
        start = end + 1
    }
}
FNR == 1 { if (file != "") scan(file, text); file = FILENAME; text = "" }
{ text = text $0 "\n" }
END { if (file != "") scan(file, text); printf "CALLS %d\n", calls + 0 }
')"

calls="$(printf '%s\n' "$report" | awk '/^CALLS /{ s += $2 } END { print s + 0 }')"
missing="$(printf '%s\n' "$report" | sed -n 's/^MISSING //p')"

if [ "$calls" -eq 0 ]; then
    echo "check-subprocess-environment: found no Subprocess.run call under Sources/APIServer" >&2
    exit 1
fi

if [ -n "$missing" ]; then
    echo "check-subprocess-environment: Subprocess.run call(s) with no environment: argument" >&2
    printf '  %s\n' $missing >&2
    echo "  Pass Subprocess::Environment.only(...) (SubprocessEnvironment.swift); the default inherits the server's secrets." >&2
    exit 1
fi

echo "check-subprocess-environment: OK ($calls calls, every one passes environment:)"
