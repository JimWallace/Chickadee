### Changed

- **A suite rebuild copies the manifest instead of rebuilding it from a list of fields.** `makeWorkerManifestJSON(preserving:)` now copies the decoded `TestProperties` and replaces only the suite, so a field no caller thought to carry survives every script edit, family apply and section change. The create paths build a `TestProperties` from nothing and encode it the same way. Slice 2 of #1655.

### Fixed

- **A suite edit no longer drops the grader-only marks.** `graderOnlyFiles` was never threaded through the old fresh-dict rebuild, so adding or removing a script, or applying a pattern family, silently cleared every mark (#1655).
