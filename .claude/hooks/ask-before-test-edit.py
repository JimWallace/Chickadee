#!/usr/bin/env python3
"""PreToolUse hook: ask before a tool changes an existing file under Tests/.

The maintainer approves every change to an existing unit test. A new test
file needs no approval. A permission rule cannot tell the two apart, because
`Edit(...)` rules match the Edit and Write tools alike, so this hook checks
whether the target file already exists.

For any other path, or a new file, the hook prints nothing and the normal
permission rules apply.
"""

import json
import os
import sys


def main() -> None:
    try:
        event = json.load(sys.stdin)
    except json.JSONDecodeError:
        return
    if not isinstance(event, dict):
        return

    tool_input = event.get("tool_input")
    if not isinstance(tool_input, dict):
        return
    path = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not isinstance(path, str) or not path:
        return

    project_dir = os.environ.get("CLAUDE_PROJECT_DIR") or event.get("cwd") or os.getcwd()
    tests_dir = os.path.realpath(os.path.join(project_dir, "Tests"))
    target = os.path.realpath(os.path.join(project_dir, path))

    if os.path.commonpath([tests_dir, target]) != tests_dir:
        return
    if not os.path.isfile(target):
        return

    relative = os.path.relpath(target, project_dir)
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": (
                    f"{relative} is an existing file under Tests/. "
                    "The maintainer approves every change to an existing test."
                ),
            }
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
