### Added

- **MCP `update_pattern_family` can now grow and re-wire a family in place.** The
  tool gained `addCases` (append brand-new cases to an existing pattern family;
  keys must not collide with an existing case) and `dependsOn` (replace the
  family's prerequisites — script filenames or `family:<id>` tokens, `[]` to
  clear). Previously an agent had to delete and recreate a whole family just to
  add coverage or drop a redundant prerequisite, which the safety classifier
  rightly blocks as destructive. Case-building logic is now shared with
  `create_pattern_family` so the two tools can't drift, and the response reports
  the appended `addedCaseKeys`.
