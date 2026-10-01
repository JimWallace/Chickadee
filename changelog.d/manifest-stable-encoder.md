### Changed

- **One writer for a stored manifest.** Every single-field edit (grading mode, language, sections, datasets, achievements, the activity block, the MCP tools) now edits the decoded `TestProperties` and stores it with `ManifestCodec.stableEncoder`, instead of editing a `[String: Any]` dictionary. Equal values store equal bytes, and `TestSuiteEntry` and `TestProperties` omit defaults when encoded, so a manifest's bytes no longer depend on which writer produced them. Slice 1 of #1655.

### Fixed

- **Deleting a support file now clears its dataset mark.** The dictionary edit looked the mark up under the wrong key, so the per-student slice survived the file it named (#1655).
