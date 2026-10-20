#!/usr/bin/env python3
"""PreToolUse hook: ask before a tool changes an existing file under Tests/.

The maintainer approves every change to an existing unit test. A new test
file needs no approval. A permission rule cannot tell the two apart, because
`Edit(...)` rules match the Edit and Write tools alike, so this hook checks
whether the target file already exists.

The maintainer wants this to be the only prompt a session sees, so the
project settings can allow every other tool call. The hook reads two kinds of
call:

- Edit, MultiEdit, Write and NotebookEdit: the target path.
- Bash: a command that writes to an existing path under Tests/ with an
  in-place editor (`sed -i`, `perl -i`), a redirect (`>`, `>>`), `tee`, or a
  command that moves, removes, copies over, truncates, patches, restores or
  reformats a named path.

The Bash check reads the named paths only. A command that changes tests
without naming them (`git reset --hard`, `git stash`, `git checkout .`)
gets no prompt.

For any other call, the hook prints nothing.
"""

import json
import os
import re
import shlex
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
from hook_common import project_dir, read_tool_event  # noqa: E402

# A command whose named paths it may change. The value is the set of the
# command's arguments that can be a write target: "all", or "last" for a
# command whose earlier arguments are only read (cp reads its sources).
WRITING_COMMANDS = {
    "mv": "all",
    "rm": "all",
    "cp": "last",
    "truncate": "all",
    "patch": "all",
    "touch": "all",
}

# Git subcommands that rewrite the named paths.
WRITING_GIT_SUBCOMMANDS = {"checkout", "restore", "apply", "rm", "mv"}

SEGMENT_SPLIT = re.compile(r"\|\||&&|[;|\n]")
REDIRECT_TARGET = re.compile(r"(?<![0-9&<])>>?\s*([^\s;|&<>]+)")


def ask(reason: str) -> None:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "ask",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )


def existing_test_path(path: str, base: str, tests_dir: str) -> str | None:
    """Returns the path relative to the project when it names an existing
    file or directory under Tests/, else None."""
    if not path or path.startswith("-"):
        return None
    target = os.path.realpath(os.path.join(base, os.path.expanduser(path)))
    if os.path.commonpath([tests_dir, target]) != tests_dir:
        return None
    if not os.path.exists(target):
        return None
    return os.path.relpath(target, os.path.dirname(tests_dir))


def split_words(segment: str) -> list[str]:
    try:
        return shlex.split(segment, posix=True)
    except ValueError:
        return segment.split()


def bash_test_targets(command: str, base: str, tests_dir: str) -> list[str]:
    """Returns the existing paths under Tests/ that the command can change."""
    found: list[str] = []

    for match in REDIRECT_TARGET.finditer(command):
        hit = existing_test_path(match.group(1).strip("\"'"), base, tests_dir)
        if hit:
            found.append(hit)

    for segment in SEGMENT_SPLIT.split(command):
        words = split_words(segment.strip())
        # Drop leading environment assignments and `sudo`.
        while words and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[0]) or words[0] == "sudo"):
            words = words[1:]
        if not words:
            continue
        name = os.path.basename(words[0])
        args = [w for w in words[1:] if not w.startswith("-")]
        candidates: list[str] = []

        if name in ("sed", "perl"):
            in_place = any(
                w == "--in-place" or w.startswith("--in-place=") or re.fullmatch(r"-[A-Za-z]*i.*", w)
                for w in words[1:]
            )
            if in_place:
                candidates = args
        elif name == "tee":
            candidates = args
        elif name in WRITING_COMMANDS:
            candidates = args[-1:] if WRITING_COMMANDS[name] == "last" else args
        elif name == "git" and len(words) > 1:
            sub = next((w for w in words[1:] if not w.startswith("-")), "")
            if sub in WRITING_GIT_SUBCOMMANDS:
                candidates = args[1:]
        elif name in ("swift-format", "swift") and "format" in words[1:]:
            if "lint" not in words[1:]:
                candidates = [a for a in args if a != "format"]

        for candidate in candidates:
            hit = existing_test_path(candidate, base, tests_dir)
            if hit:
                found.append(hit)

    return sorted(set(found))


def main() -> None:
    read = read_tool_event()
    if read is None:
        return
    event, tool_input = read

    project = project_dir(event)
    tests_dir = os.path.realpath(os.path.join(project, "Tests"))

    if event.get("tool_name") == "Bash":
        command = tool_input.get("command")
        if not isinstance(command, str) or not command:
            return
        base = event.get("cwd") or project
        targets = bash_test_targets(command, base, tests_dir)
        if targets:
            ask(
                f"This command can change {', '.join(targets)} under Tests/. "
                "The maintainer approves every change to an existing test."
            )
        return

    path = tool_input.get("file_path") or tool_input.get("notebook_path")
    if not isinstance(path, str) or not path:
        return

    target = os.path.realpath(os.path.join(project, path))
    if os.path.commonpath([tests_dir, target]) != tests_dir:
        return
    if not os.path.isfile(target):
        return

    relative = os.path.relpath(target, project)
    ask(
        f"{relative} is an existing file under Tests/. "
        "The maintainer approves every change to an existing test."
    )


if __name__ == "__main__":
    main()
