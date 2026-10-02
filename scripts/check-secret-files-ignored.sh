#!/usr/bin/env bash
set -uo pipefail

# Every file that holds a secret is git-ignored.
#
# The names are read from the header of Sources/APIServer/Helpers/SecretFile.swift,
# which lists every secret file the server writes, so a fifth secret file is
# guarded the day its writer is documented beside the others. Each name is
# checked with git check-ignore, the same answer `git add` would give.
#
# Why this exists: `.lti-tool-key` and `.github-app-secrets` were written to
# the working directory by default and were absent from .gitignore for the
# whole life of both features (#1772). A developer running the server from a
# checkout could have committed an App private key with `git add .`.

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"

source_file="Sources/APIServer/Helpers/SecretFile.swift"
names="$(sed -n '1,12p' "$source_file" | grep -o '`\.[a-z-]*`' | tr -d '`' | sort -u)"

if [ -z "$names" ]; then
    echo "check-secret-files-ignored: found no secret file names in $source_file" >&2
    exit 1
fi

status=0
count=0
for name in $names; do
    count=$((count + 1))
    if ! git check-ignore -q "$name"; then
        echo "check-secret-files-ignored: $name is not ignored by .gitignore" >&2
        status=1
    fi
done

if [ "$count" -lt 4 ]; then
    echo "check-secret-files-ignored: expected at least 4 secret file names, found $count" >&2
    exit 1
fi

if [ "$status" -eq 0 ]; then
    echo "check-secret-files-ignored: OK ($count secret files ignored)"
fi
exit "$status"
