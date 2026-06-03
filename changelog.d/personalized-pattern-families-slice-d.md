### Added

- **Author per-student pattern families in the editor (issue #461, slice D).**
  The in-browser pattern-family editor now supports per-student cases: type
  `$name` in the Expected cell (or an arg cell) to reference a global/section
  `=` expression, resolved per student at grading time. The editor learns the
  Global Input / expression names (so per-student refs validate + highlight
  instead of being red-flagged), serializes the Expected ref as `expectedVarRef`,
  and skips Pyodide auto-compute for per-student rows. Personalized families
  (#816/#817/#818) are now authorable in the browser, completing the A–D arc of
  `docs/personalization-pattern-families.md`.
