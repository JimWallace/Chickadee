### Added

- **Per-student datasets can now derive values, not just select rows.** A
  `DatasetSpec` carries an ordered `transforms` list alongside its selection
  `kind`, so the instructor's pool becomes a template each student varies on.
  The first transform is `missingValues`, which blanks a deterministic subset of
  cells in explicitly named columns — teaching the handling of absent data,
  which real health datasets arrive with. Selection runs first and transforms in
  order, each drawing from its own sub-seeded stream so appending a step never
  re-rolls an earlier one, and no `Double` reaches a delivered byte. A transform
  never adds, removes, renames or reorders a column. Authored through
  `set_dataset` and the two datasets endpoints; the Files panel does not offer
  it yet, and deliberately will not until validation covers more than the
  instructor's own variant.

### Fixed

- **The Files panel and `set_dataset` no longer rebuild a dataset spec from only
  the fields they know about.** Both constructed a fresh spec on every edit, so
  a setting one of them had not been taught about would be dropped by an
  unrelated change — the shape that came within a release of silently
  downgrading every stratified spec to a plain sample. Both now carry forward
  what they were not asked to change. The datasets endpoints also read the
  source file when a spec carries transforms, not only when it stratifies, so a
  transform naming a column the file lacks is refused at save rather than
  ignored at delivery.
