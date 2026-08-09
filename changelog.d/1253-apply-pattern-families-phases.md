### Changed

- **`applyPatternFamilies` no longer suppresses a cyclomatic-complexity
  warning.** Its render-and-write phase and its suite-entry-building phase
  moved into `PatternFamilyApplication+ZipMutation.swift` and
  `+SuiteEntries.swift`, taking the function from a 575-line body to 306 and
  dropping its complexity below the threshold on its own — so the repo's only
  double lint exemption is now a single one. No behavioural change: the
  manifests and zip file lists produced for a fixture covering families,
  existence guards, notebook checks with sidecars, sections, global variables,
  `family:` dependency expansion, disabled cases and the deletion diff are
  unchanged.
