#!/usr/bin/env bash
set -euo pipefail

# Every tmpfs mount in docker-compose.yml must say `exec`.
#
# Docker mounts a tmpfs with `noexec` unless its options include `exec`, so
# `/tmp:size=1g` is a noexec mount. The runner's work root lives on /tmp, and a
# C++ test compiles into the work root and runs the binary from there. On a
# noexec work root the runner's startup probe cannot run its compiled probe, so
# the runner silently stops advertising C++, and every C++ job waits for a
# runner that never comes. That shipped: the compose comment said the mount
# "must NOT carry noexec" while the line itself carried it by default, and on
# 2026-10-05 all three production runners had lost C++.
#
# Deliberately awk and shell: format-lint runs an image with no python3.

compose_file="${1:-docker-compose.yml}"

problems="$(awk '
    function indent(s) { match(s, /^ */); return RLENGTH }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*tmpfs:[[:space:]]*$/ { in_tmpfs = 1; key_indent = indent($0); next }
    in_tmpfs {
        if ($0 ~ /^[[:space:]]*$/) next
        if (indent($0) <= key_indent) { in_tmpfs = 0; next }
        entry = $0
        sub(/^[[:space:]]*-[[:space:]]*/, "", entry)
        gsub(/["\047]/, "", entry)
        split(entry, parts, ":")
        options = (length(parts) > 1) ? parts[2] : ""
        if (("," options ",") !~ /,exec,/) {
            printf "%s:%d: tmpfs %s has no exec option, so Docker mounts it noexec\n", FILENAME, NR, entry
        }
    }
' "$compose_file")"

if [ -n "$problems" ]; then
    printf '%s\n' "$problems"
    echo "Add exec to the mount options, for example /tmp:size=1g,exec. A noexec work root stops the runner from advertising C++."
    exit 1
fi
echo "compose tmpfs mounts: every mount says exec"
