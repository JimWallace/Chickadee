### Changed

- **The test suites spawn interpreters through one helper, on `swift-subprocess`.**
  `Tests/TestSupport/InterpreterSpawn.swift` replaces the Foundation `Process`
  spawns that 37 test files built by hand, in two shapes repeated almost
  verbatim: an availability probe, and a script run in a directory with its
  output captured.

  This attacks a named open lead rather than only tidying. `docs/ci-flakiness.md`
  Family 5 still carries "a subprocess storm" as a live hypothesis, measured as
  21 of APITests' 376 files both spawning `Process()` and naming a real
  interpreter. Every one of those now goes through a spawner that does not share
  the global state Foundation's `Process` races on — the race the zip path
  needed a process-wide lock and an EFAULT retry to contain, both deleted in the
  previous change.

  The helper carries the same one-shot environment snapshot `Core/ZipSubprocess`
  does, for the same reason: a per-spawn environ read races `setenv`, and these
  suites write environment variables while Swift Testing runs them concurrently.

  Three spawns are deliberately left on Foundation `Process`, because migrating
  them would delete what they exist to do: `PipeCloseOnExecTests` (its subject
  is `Pipe` inheritance across a real `exec`), `LocalHTTPTestServer` (a
  long-lived server the collected API does not model), and
  `ScriptRunnerTestSupport` (the spawn-retry harness, which takes a `Process`
  factory by design). The file header names all three.
