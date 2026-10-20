#!/usr/bin/env python3
"""PostToolUse hook: run swift-format on a Swift file after a tool edits it.

CI fails the format-lint job on any file that `swift-format lint --strict`
rejects. This hook formats each Swift file in place as soon as Edit, MultiEdit
or Write changes it, with the rules in .swift-format, so that failure does not
reach CI. It does the same work as scripts/format.sh, for one file.

The hook prints nothing and does nothing when the file is not a Swift file in
this project, or when swift-format is not installed. A formatting error does
not stop the session: the format-lint job reports it later.
"""

import os
import shutil
import subprocess
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from hook_common import environment_with_toolchain, project_dir, read_tool_event  # noqa: E402


def main() -> None:
    read = read_tool_event()
    if read is None:
        return
    event, tool_input = read
    path = tool_input.get("file_path")
    if not isinstance(path, str) or not path.endswith(".swift"):
        return

    project = os.path.realpath(project_dir(event))
    target = os.path.realpath(os.path.join(project, path))
    if os.path.commonpath([project, target]) != project or not os.path.isfile(target):
        return

    env = environment_with_toolchain()
    swift_format = shutil.which("swift-format", path=env.get("PATH"))
    if swift_format is None:
        return

    subprocess.run(
        [swift_format, "format", "--in-place", target],
        cwd=project,
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
        timeout=60,
    )


if __name__ == "__main__":
    main()
