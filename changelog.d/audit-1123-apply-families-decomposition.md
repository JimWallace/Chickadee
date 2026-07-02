### Changed

- **`applyPatternFamilies` decomposed (#1123).** Generated scripts are now
  rendered exactly once per apply (`renderFamilyArtifacts`) and both the zip
  write and the manifest rebuild consume the same artifacts — previously each
  family was rendered twice, so a renderer that ever became non-deterministic
  would silently desync zip bytes from manifest entries. The duplicate
  `familyID → sectionID` map is built once; the legacy ordering
  reconstruction, the section-contiguity validator (now unit-tested), the
  `family:<id>` reference validation, and the raw-script variable re-inline
  are free functions; and the drifted phase markers are renumbered. No
  behavior change.
