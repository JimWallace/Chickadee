### Added

- **`unordered_equality` pattern-family kind (issue #461).** A new kind for
  functions that return a list where order isn't part of the contract (e.g.
  "find all patients with diagnosis X"): each element is canonicalised (JSON with
  sorted keys, `str()` fallback) and the two multisets are compared, so a
  correct-but-reordered result passes where `boundary_equality` would false-fail.
  Supports per-student `argVarRefs` / `expectedVarRef`. Available in the
  assignment editor's family-kind dropdown, the New-Family modal, and via
  `create_pattern_family` / `update_pattern_family`.
