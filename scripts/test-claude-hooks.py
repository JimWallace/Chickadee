#!/usr/bin/env python3
"""Behaviour tests for the Claude Code hooks in .claude/hooks/.

Each case runs one hook as Claude Code does: one JSON event on stdin, in a
temporary project directory. The case then checks the decision that the hook
prints, or the file that it changes.

Run it with no arguments. It exits 0 when every case passes and 1 when one
fails.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.realpath(__file__)))
HOOKS = os.path.join(REPO, ".claude", "hooks")

failures: list[str] = []


def run_hook(hook: str, event: dict, project: str) -> str:
    env = dict(os.environ, CLAUDE_PROJECT_DIR=project)
    result = subprocess.run(
        [sys.executable, os.path.join(HOOKS, hook)],
        input=json.dumps(dict(event, cwd=project)),
        capture_output=True,
        text=True,
        env=env,
        cwd=project,
        check=False,
        timeout=120,
    )
    if result.returncode != 0:
        return f"exit {result.returncode}: {result.stderr.strip()}"
    if not result.stdout.strip():
        return "none"
    return json.loads(result.stdout)["hookSpecificOutput"]["permissionDecision"]


def expect(name: str, actual: str, wanted: str) -> None:
    status = "ok  " if actual == wanted else "FAIL"
    print(f"{status} {name}: {actual!r}")
    if actual != wanted:
        failures.append(f"{name}: wanted {wanted}, got {actual}")


def make_project() -> str:
    project = tempfile.mkdtemp(prefix="claude-hooks-")
    os.makedirs(os.path.join(project, "Tests", "CoreTests"))
    os.makedirs(os.path.join(project, "Sources"))
    with open(os.path.join(project, "Tests", "CoreTests", "Existing.swift"), "w") as f:
        f.write("let a = 1\n")
    with open(os.path.join(project, "Sources", "Code.swift"), "w") as f:
        f.write("let b = 2\n")
    return project


def test_edit_hook() -> None:
    project = make_project()
    hook = "ask-before-test-edit.py"
    existing = "Tests/CoreTests/Existing.swift"
    try:
        def edit(tool: str, path: str) -> str:
            return run_hook(hook, {"tool_name": tool, "tool_input": {"file_path": path}}, project)

        def bash(command: str) -> str:
            return run_hook(hook, {"tool_name": "Bash", "tool_input": {"command": command}}, project)

        expect("Edit of an existing test asks", edit("Edit", existing), "ask")
        expect("Write of an existing test asks", edit("Write", existing), "ask")
        expect("Write of a new test file passes", edit("Write", "Tests/CoreTests/New.swift"), "none")
        expect("Edit of a source file passes", edit("Edit", "Sources/Code.swift"), "none")

        expect("sed -i on a test asks", bash(f"sed -i 's/a/b/' {existing}"), "ask")
        expect("perl -pi on a test asks", bash(f"perl -pi -e 's/a/b/' {existing}"), "ask")
        expect("redirect into a test asks", bash(f"echo x > {existing}"), "ask")
        expect("append to a test asks", bash(f"echo x >> {existing}"), "ask")
        expect("tee into a test asks", bash(f"echo x | tee {existing}"), "ask")
        expect("rm of a test directory asks", bash("rm -rf Tests/CoreTests"), "ask")
        expect("mv of a test asks", bash(f"mv {existing} /tmp/x.swift"), "ask")
        expect("cp over a test asks", bash(f"cp Sources/Code.swift {existing}"), "ask")
        expect("git checkout of a test asks", bash(f"git checkout main -- {existing}"), "ask")
        expect("swift-format format of a test asks", bash(f"swift-format format --in-place {existing}"), "ask")
        expect("a write after && asks", bash(f"cd . && sed -i 's/a/b/' {existing}"), "ask")

        expect("sed -n on a test passes", bash(f"sed -n 1p {existing}"), "none")
        expect("redirect from a test to /tmp passes", bash(f"cat {existing} > /tmp/out.txt"), "none")
        expect("2>&1 after a test read passes", bash(f"grep -n a {existing} 2>&1 | head"), "none")
        expect("cp from a test passes", bash(f"cp {existing} /tmp/copy.swift"), "none")
        expect("redirect into a new test file passes", bash("echo x > Tests/CoreTests/New.swift"), "none")
        expect("swift-format lint of a test passes", bash(f"swift-format lint {existing}"), "none")
        expect("swift test passes", bash("swift test --filter CoreTests"), "none")
        expect("sed -i on a source file passes", bash("sed -i 's/b/c/' Sources/Code.swift"), "none")
    finally:
        shutil.rmtree(project)


def test_pre_push_hook() -> None:
    hook = "pre-push-format-lint.py"
    for lint_exit, label in ((1, "failing"), (0, "passing")):
        project = make_project()
        try:
            script = os.path.join(project, "scripts", "format-lint.sh")
            os.makedirs(os.path.dirname(script))
            with open(script, "w") as f:
                f.write(f"#!/bin/sh\necho 'FAILED: scripts/lint.sh'\nexit {lint_exit}\n")
            os.chmod(script, 0o755)

            def bash(command: str) -> str:
                return run_hook(hook, {"tool_name": "Bash", "tool_input": {"command": command}}, project)

            push_result = "deny" if lint_exit else "none"
            expect(f"git push with {label} lint", bash("git push -u origin work"), push_result)
            expect(f"push after a commit -n with {label} lint", bash("git commit -n -m x && git push"), push_result)
            expect(f"git push --delete with {label} lint", bash("git push origin --delete work"), "none")
            expect(f"git push --dry-run with {label} lint", bash("git push --dry-run"), "none")
            expect(f"git status with {label} lint", bash("git status"), "none")
        finally:
            shutil.rmtree(project)


def test_format_hook() -> None:
    hook = "format-swift.py"
    if shutil.which("swift-format") is None:
        failures.append("format-swift.py: swift-format is not installed, so its cases cannot run")
        print("FAIL format-swift.py: swift-format is not installed")
        return
    project = make_project()
    try:
        with open(os.path.join(REPO, ".swift-format")) as src, open(os.path.join(project, ".swift-format"), "w") as dst:
            dst.write(src.read())
        source = os.path.join(project, "Sources", "Bad.swift")
        text = os.path.join(project, "Sources", "notes.txt")
        for path in (source, text):
            with open(path, "w") as f:
                f.write("let   x =  1\n")

        run_hook(hook, {"tool_name": "Edit", "tool_input": {"file_path": "Sources/Bad.swift"}}, project)
        run_hook(hook, {"tool_name": "Edit", "tool_input": {"file_path": "Sources/notes.txt"}}, project)
        with open(source) as f:
            expect("a Swift file is formatted", f.read(), "let x = 1\n")
        with open(text) as f:
            expect("a text file is not changed", f.read(), "let   x =  1\n")
    finally:
        shutil.rmtree(project)


def main() -> None:
    test_edit_hook()
    test_pre_push_hook()
    test_format_hook()
    if failures:
        print(f"\n{len(failures)} case(s) failed:")
        for failure in failures:
            print(f"  {failure}")
        sys.exit(1)
    print("\nclaude-hooks self-test: OK")


if __name__ == "__main__":
    main()
