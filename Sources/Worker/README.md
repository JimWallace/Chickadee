# chickadee-runner

Worker daemon. Polls the API server for pending jobs, runs instructor-defined shell-script test suites in subprocesses, and reports structured results back.

---

## CLI flags

| Flag | Type | Description |
|------|------|-------------|
| `--api-base-url` | `String` | Base URL of the API server (e.g. `http://localhost:8080`) |
| `--worker-id` | `String` | Unique identifier for this worker instance |
| `--max-jobs` | `Int` | Maximum number of concurrent jobs |
| `--sandbox` | `Bool` (flag) | Run test scripts inside a network-isolated, privilege-dropped sandbox |

Example:

```bash
chickadee-runner \
  --api-base-url http://localhost:8080 \
  --worker-id    worker-1 \
  --max-jobs     4 \
  --sandbox
```

---

## Test script contract

Each test suite is a shell script run as `/bin/sh <script>` from the test-setup directory as the working directory.

| Exit code | Outcome |
|-----------|---------|
| `0` | `pass` |
| `1` | `fail` |
| `2` | `error` |
| Killed after timeout | `timeout` |

**stdout:** Everything is ignored except the last non-empty line, which is attempted as JSON:

```json
{ "shortResult": "3/4 cases passed" }
```

If the last line is not valid JSON it is used as plain-text `shortResult`. If stdout is empty, `shortResult` is synthesised from the exit code (`"passed"` / `"failed"` / `"error"`).

**stderr:** Captured verbatim as `longResult` (`nil` if empty).

**Build failure:** If a `make` step exits non-zero, the run is recorded as `buildStatus: "failed"` with `outcomes: []`. There is no per-test "could not run" state.

---

## Sandboxing

`ScriptRunner` is the sandbox boundary. Two implementations exist:

- **`UnsandboxedScriptRunner`** — direct subprocess, no restrictions. Default when `--sandbox` is omitted. Suitable for development.
- **`SandboxedScriptRunner`** — wraps execution in an OS-level sandbox. Enable with `--sandbox` in production.

| Platform | Mechanism | Restrictions |
|----------|-----------|-------------|
| macOS | `sandbox-exec -p <profile>` | Network denied; file writes confined to the working directory |
| Linux | `unshare --user --net --map-root-user` | Private network namespace (no external routes); UID mapped to unprivileged user inside the namespace |

Both implementations honour the same timeout, stdout/stderr capture, and exit-code mapping as the unsandboxed runner. No call sites change when switching between them.
