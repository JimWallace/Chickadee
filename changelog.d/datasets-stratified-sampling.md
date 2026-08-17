### Added

- **Per-student datasets can be balanced across a column.** A dataset spec now
  takes a `stratumColumn`, and `DatasetKind` a `stratifiedSample` case: the
  sample is apportioned across that column's distinct values so every category
  in the pool appears in every student's slice. A plain row sample can drop a
  rare category outright, which quietly turns a `groupby` exercise into a
  different exercise for the student who lost it. Set it from the Files panel
  (an empty column box means a plain sample, so there is no separate kind to
  keep in step) or with `set_dataset`; `get_support_files` reports both.
  Apportionment is Hamilton's method with one row per category guaranteed,
  in integer arithmetic — the materializer's contract is byte-identical output
  for the same seed forever, and floating-point rounding would be an invisible
  way to lose it. `rowSample`'s existing output is unchanged, pinned by a
  fixture test committed before the change.

### Changed

- **A dataset spec that does not fit its file is now refused at save time.**
  Both datasets endpoints and `set_dataset` check a stratified spec against the
  file it marks: the column must exist in the header, and the sample must have
  room for every category. The messages name the file's actual columns and its
  category count. Delivery still degrades rather than failing — an unknown
  column falls back to a plain row sample — because by then the only reader is
  a student being graded, and that forgiveness is only safe if the mistake is
  caught where an instructor can still fix it.
