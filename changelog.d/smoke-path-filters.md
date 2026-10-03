### Fixed

- **Two CI path filters named files that no longer exist.** `editor-smoke.yml` listed `assignment-validate.js` and `embedded-activity.js`, and only three of the eight grading and eval workers, so a change to a Lua or Octave worker, or to the shared grading scripts the notebook page loads, skipped the editor smoke. It now matches the per-language scripts with a pattern, as `browser-grading-smoke.yml` does. `grading-hang-probe.yml` filtered on `grading-worker.js`, which became one worker per language; it now uses globs (#1981).
