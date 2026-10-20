"""Shared code for the Claude Code hooks in this directory.

Each hook reads one JSON event on stdin, takes the tool input from it, and
works in the project directory. A hook also runs with the PATH of the Claude
Code process, not the PATH of the session's shell. In a cloud session,
.claude/hooks/session-start.sh installs the toolchain under ~/swift/ and adds
it to the shell PATH only, so a hook cannot find `swift` or `swift-format`
without `environment_with_toolchain`. On a local machine the toolchain is
already on PATH, and that function changes nothing.
"""

import glob
import json
import os
import shutil
import sys


def read_tool_event() -> tuple[dict, dict] | None:
    """Returns the event on stdin and its `tool_input`, or None when the
    event is not a JSON object with a `tool_input` object."""
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return None
    if not isinstance(event, dict):
        return None
    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return None
    return event, tool_input


def project_dir(event: dict) -> str:
    """Returns the project directory: CLAUDE_PROJECT_DIR, else the event's
    working directory, else the process's."""
    return os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or os.getcwd()


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
