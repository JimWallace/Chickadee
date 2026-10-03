### Added

- **A guard that every task the server starts has an owner.** A new test reads `Sources/APIServer` for a task created and not kept (a line that starts `Task {`, `Task(`, `Task.detached` or `_ = Task`) and fails unless an allowlist says why it is safe. The allowlist is empty. A task nobody keeps can outlive the application, and one that uses the database then queries a closed one (#1700). The last such task, the diagnostics prune at boot, now runs on `Application.backgroundWork`, which shutdown waits for. Closes #1948.
