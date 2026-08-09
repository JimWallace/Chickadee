### Fixed

- **Racket assignments are gradable.** Two runner defects closed together, both
  from the multi-language audit:
  - A generated `.rkt` test had no `ScriptInterpreter` case and no extension arm,
    so it classified as unknown, fell through to `/bin/sh`, and exited 2 on its
    own leading `;` — every generated Racket test reporting `error`, in the only
    grading path an upload-only language has.
  - `RunnerProfileDetector.firstNumericVersion` could not read
    `Welcome to Racket v8.10 [cs].` because the version token is letter-led, so
    no runner ever advertised `racket` and `RunnerLanguageGate` refused every
    runner — jobs queued forever with no error, no failed test and no log line,
    instructor validation included.

### Changed

- **Three guards, each the one that would have caught its defect.**
  `GeneratedScriptDispatchTests` asserts from `allCases` that every language's
  generated extension reaches its own interpreter (C++'s `.sh` wrapper is the
  stated exception). `RunnerProfileDetectorTests` — the detector's first test of
  any kind — pins all six real banners and, under CI, asserts each probe's live
  output *parses* rather than merely exiting 0. `RacketNativeGradingTests`
  executes generated `.rkt` through a real interpreter, so Racket meets the
  runbook's done test rather than being declared finished.

**Operational note:** dispatch and the runtime helper both live in the runner
binary, so a Racket assignment needs a runner at this version or newer. Refresh
the fleet before opening one.
