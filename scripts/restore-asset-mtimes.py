#!/usr/bin/env python3
"""Set each tracked file under the given paths to the time of its last commit.

The server's ETag for a static file is its mtime plus its size, and Docker
COPY keeps the mtime from the build context. A fresh checkout stamps every
file with the checkout time, so without this step each deploy gives every
vendored file a new ETag, and browsers download unchanged kernel files again.

Usage: scripts/restore-asset-mtimes.py [path ...]   (default: Public)

It reads the first-parent history once, so a file gets the time at which its
latest change reached the branch (for a merged pull request, the merge time).
A file that the history does not show, for example in a shallow clone, gets
the HEAD commit time. It needs a full-history checkout; a blob:none partial
clone is enough, because only trees are read.

It replaces git-restore-mtime here: the 2022 release that Ubuntu 24.04 ships
calls `git whatchanged`, which current git refuses, and it then updates no
file and still exits 0. This script fails when it updates no file.
"""

import os
import subprocess
import sys


def git(*args: str) -> str:
    return subprocess.run(
        ["git", "-c", "core.quotePath=false", *args],
        check=True,
        capture_output=True,
        text=True,
    ).stdout


def main() -> int:
    paths = sys.argv[1:] or ["Public"]
    pending = {name for name in git("ls-files", "--", *paths).splitlines() if name}
    if not pending:
        print(f"restore-asset-mtimes: no tracked files under {' '.join(paths)}", file=sys.stderr)
        return 1
    total = len(pending)

    log = subprocess.Popen(
        [
            "git", "-c", "core.quotePath=false", "log",
            "--first-parent", "--diff-merges=first-parent",
            "--name-only", "--no-renames", "--format=@%ct", "--", *paths,
        ],
        stdout=subprocess.PIPE,
        text=True,
    )
    assert log.stdout is not None
    commit_time = None
    for line in log.stdout:
        line = line.rstrip("\n")
        if line.startswith("@"):
            commit_time = int(line[1:])
        elif line in pending and commit_time is not None:
            os.utime(line, (commit_time, commit_time))
            pending.discard(line)
            if not pending:
                break
    log.kill()
    log.wait()

    updated = total - len(pending)
    if pending:
        head_time = int(git("log", "-1", "--format=%ct", "HEAD").strip())
        for name in pending:
            os.utime(name, (head_time, head_time))
    print(f"restore-asset-mtimes: {updated} of {total} files set from history, "
          f"{len(pending)} set to the HEAD commit time")
    if updated == 0:
        print("restore-asset-mtimes: no file was found in the history. "
              "Is the checkout shallow?", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
