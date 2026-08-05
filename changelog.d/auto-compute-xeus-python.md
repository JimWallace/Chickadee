### Changed

- **The pattern-family editor's auto-compute runs on xeus-python (#1271).**
  `Public/pyodide-worker.js` is replaced by `Public/python-eval-worker.js`, which
  boots the same vendored `chickadee-python` kernel the editor and the browser
  grader use. Auto-compute produces the expected value a generated test will then
  assert, so having it run on a different interpreter — with a different numpy —
  from the one that grades it was a real source of "the value it computed is not
  the value the test reproduces". No behaviour change from an instructor's side:
  the worker protocol and the timeout contract are unchanged.

  With this, **no Chickadee-owned JavaScript loads Pyodide.** The only remaining
  consumer is the vendored `jupyterlite-pyodide-kernel`, whose removal — and with
  it the ~465 MB `Public/pyodide` and the `unsafe-eval` in the CSP — needs a
  JupyterLite rebuild that CI cannot run.

### Fixed

- **A long-running browser-graded test could have reported a bogus result.** The
  xeus `execute` helper polled a fixed number of times for the kernel's reply,
  which read like a 2-second execution timeout; a test that really exceeded it
  would have returned whatever partial output existed, with no error. In practice
  it never fired — a xeus-lite cell runs inside `notify_listener`, so a slow cell
  blocks the worker's event loop and the reply is in hand before the poll gets a
  turn, which is why the R smoke grades a 3,139 ms script under a 2,000 ms cap.
  The cap is now a named, overridable dead-kernel backstop rather than an
  accidental limit, and the auto-compute worker sets a much larger one because
  its legitimate waits are longer.
