### Added

- **Review: what the corrected Leaf rule unblocks.** `docs/leaf-decomposition-review.md`
  sizes the `assignment-new` / `_assignment-edit-body` duplication against real diffs
  rather than marker counts, and lands on a four-slice plan. Verifies (control-first,
  with a falsified assertion) that three inline partial includes resolve inside an
  extend/export block. Records two live create-page defects traced to duplicated
  JavaScript rather than to template structure: per-student `=` expressions degrade to
  literal strings in section inputs, and section drag-reorder raises a spurious failure
  alert because a second, redundant handler posts to an endpoint that does not accept
  the method.
