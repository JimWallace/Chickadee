### Added

- **R assignments compute expected values in the browser.** Auto-compute used to
  send every non-Python language to the server, which was the right fix for a
  wrong answer and the wrong rule for an editor whose job is in-browser
  authoring: an instructor changing a case should see what their solution
  returns without a round-trip. R now runs on the vendored xeus-r kernel, the
  same one that grades a browser-graded R submission.

  Lua and Octave still route to the server. Their kernels exist and the worker
  shape is now proven; each needs its own snippet module and a smoke row.

- **`rLiteral` in `Public/r-grading-shared.js`** — a browser twin of
  `JSONValue.rLiteral`, needed because in-page auto-compute calls an R solution
  with arguments the instructor has typed but not saved, so there is no server
  round-trip in which the server could render them. Neither implementation owns
  the expectations: both read `Tests/Fixtures/r-literal-contract.json`, so a
  change to either that is not mirrored fails on both sides — the arrangement
  `output-contract.json` already uses to pin RunnerCore's native and wasm builds
  together.

- **A browser-grading smoke row for R auto-compute.** It exercises the kernel
  for real, because every way these snippets can be wrong is silent: they must
  be one top-level expression each (a xeus-lite performance constraint), they
  report behind a nonce, and the seeded escaper has to be defined before any of
  them runs. The probe reads that escaper out of the Swift constant that defines
  it rather than copying it — a copy would have been the fourth R JSON encoder
  in this repo.
