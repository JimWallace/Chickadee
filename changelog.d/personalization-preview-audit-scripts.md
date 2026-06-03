### Changed

- **`preview_personalization` audit now covers test scripts (issue #461).** Its
  `{{placeholder}}` audit also reports the per-student inputs that a pattern
  family's test-script cases reference (`$name` `argVarRefs` + `expectedVarRef`),
  not just notebook `{{markers}}` — so `placeholders.used` / `unresolved` reflect
  grading too. (`get_suite` already surfaces `expectedVarRef` / `argVarRefs` via
  the Codable family spec, so the read-side round-trip was already complete.)
