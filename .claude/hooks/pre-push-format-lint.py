#!/usr/bin/env python3
"""PreToolUse hook: run the format-lint job before a `git push`.

CLAUDE.md asks for the format-lint checks before each push. This hook makes
that a gate: when a Bash command runs `git push`, the hook runs
scripts/format-lint.sh, which reads its steps from the CI format-lint job. When
a step fails, the hook stops the push and gives Claude the failing steps. When
every step passes, the push runs with no prompt.

`git push --delete` and `git push --dry-run` are not stopped, because they do
not send new code.
"""

import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from hook_common import environment_with_toolchain, project_dir, read_tool_event  # noqa: E402

GIT_PUSH = re.compile(r"(?:^|[;&|(\s])git\s+(?:-[^\s]+\s+)*push\b")
NO_CODE_FLAGS = ("--delete", "--dry-run", " -d ", " -n ")


def main() -> None:
    read = read_tool_event()
    if read is None or read[0].get("tool_name") != "Bash":
        return
    event, tool_input = read
    command = tool_input.get("command")
    if not isinstance(command, str):
        return
    match = GIT_PUSH.search(command)
    if match is None:
        return
    push_args = re.split(r"[;&|\n]", command[match.end() :], maxsplit=1)[0]
    if any(flag in f" {push_args} " for flag in NO_CODE_FLAGS):
        return

    project = project_dir(event)
    script = os.path.join(project, "scripts", "format-lint.sh")
    if not os.path.isfile(script):
        return

    result = subprocess.run(
        [script],
        cwd=project,
        env=environment_with_toolchain(),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return

    # The summary is at the end of the output. Keep the last lines, which name
    # each failing step, and enough of the log above them to show the error.
    tail = "\n".join(result.stdout.strip().splitlines()[-60:])
    if result.returncode == 2:
        reason = (
            "scripts/format-lint.sh could not read the format-lint job from "
            ".github/workflows/swift-tests.yml, so the push did not run. "
            "Fix the script or the workflow, then push again.\n\n" + tail
        )
    else:
        reason = (
            "scripts/format-lint.sh failed, so the push did not run. "
            "Fix each failing step, then push again.\n\n" + tail
        )
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


if __name__ == "__main__":
    main()
