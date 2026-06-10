### Changed

- **Achievements unification (C1): seed-on-first-save for the unified editor.**
  `TestProperties` gains `builtInAchievementsSeeded`. Until an instructor first
  saves the unified Achievements table, `GET /achievements` merges the built-in
  defaults into the rows so they appear as editable defaults; the unified `PUT`
  marks the manifest seeded, after which it is authoritative (a removed built-in
  stays removed). The flag survives suite rebuilds.
