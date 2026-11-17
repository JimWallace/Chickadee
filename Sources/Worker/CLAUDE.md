# Worker — Area Rules

Claude Code loads this file when it works under `Sources/Worker/`. The rules
for the whole repository are in the root `CLAUDE.md`.

---

**`ScriptRunner` is the sandbox boundary.** `SandboxedScriptRunner` is the
default since 0.6.0 (#2348), using platform sandboxing (macOS: `sandbox-exec`;
Linux: `unshare` user/net namespaces). `--no-sandbox` selects
`UnsandboxedScriptRunner`; `--sandbox` is still accepted and changes nothing.

**Runner-side LRU test setup cache (v0.4.41).** `TestSetupCache` (Swift actor,
default 16 entries) keeps fully-prepared test setup directories keyed by
`testSetupID`. Cache key hashes manifest + zip content, so any suite edit
busts the entry. Concurrent jobs for the same setup share one in-flight
population task.

**New runner behaviour takes a CLI flag, not an environment variable.** Add a
flag on `chickadee-runner`, as `--no-sandbox` and `--max-jobs` do, or detect the
condition at runtime (root `CLAUDE.md`, "What Not To Do").

**A runner claims only a job it can grade (`RunnerLanguageGate`).** See the
root `CLAUDE.md`, "Assignment languages", and
`docs/runner-capability-profiles.md`.
