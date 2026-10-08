### Changed

- **Claude Code asks only before an existing test changes.** A PreToolUse hook (`.claude/hooks/ask-before-test-edit.py`) asks for approval when a tool edits a file that already exists under `Tests/`. A new test file needs no approval. The hook replaces the `Edit(/Tests/**)` ask rule, which also stopped new test files. The `git diff` and `git status` allow rules now use the stricter prefix form.
