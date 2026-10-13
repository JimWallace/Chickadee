"""Finds the Swift toolchain for a hook process.

A hook runs with the PATH of the Claude Code process, not the PATH of the
session's shell. In a cloud session, .claude/hooks/session-start.sh installs
the toolchain under ~/swift/ and adds it to the shell PATH only, so a hook
cannot find `swift` or `swift-format`. On a local machine the toolchain is
already on PATH, and this module changes nothing.
"""

import glob
import os
import shutil


def environment_with_toolchain() -> dict[str, str]:
    """Returns a copy of the environment whose PATH finds `swift`."""
    env = dict(os.environ)
    if shutil.which("swift", path=env.get("PATH")) is not None:
        return env
    home = os.path.expanduser("~")
    candidates = sorted(glob.glob(os.path.join(home, "swift", "*", "usr", "bin")), reverse=True)
    for directory in candidates:
        if os.access(os.path.join(directory, "swift"), os.X_OK):
            env["PATH"] = directory + os.pathsep + env.get("PATH", "")
            break
    return env
