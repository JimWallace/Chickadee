### Fixed

- **Per-student pattern-family validation messages name the full supported
  set.** The validator's error for a per-student `$name` / `expectedVarRef`
  on an unsupported kind still claimed only `boundary_equality` and
  `approximate_equality` were allowed; `unordered_equality` gained the
  personalization preamble but the messages (and docs) were never updated.
  The messages now derive from a single description constant kept next to
  the `kindSupportsPerStudentRefs` allowlist, and the design doc / CLAUDE.md
  status notes for #814 were refreshed (both previously-listed follow-ups —
  `expectedVarRef` on the `get_suite` DTO and the `preview_personalization`
  test-script audit — had already shipped).
