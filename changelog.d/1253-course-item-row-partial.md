### Fixed

- **Assignments outside a section were missing the retest and copy-link
  actions.** The instructor dashboard's sections table and its ungrouped table
  rendered the same row markup from two copies, and the copies had drifted: the
  ungrouped one had lost the "Retest all submissions" form from every status and
  the "Copy student link" button from staff-only-preview assignments. The
  ungrouped table is also the flat-table mode a course falls back to when it has
  no sections at all, so on such a course those actions were absent for every
  assignment. Both tables now render one shared partial.
- **The publish form's title and due-date inputs carried two `class`
  attributes**, so the `editor-input` styling on the second was discarded by the
  parser. Merged into one attribute.

### Changed

- **`assignments.leaf` halved, 1,140 → 545 lines.** The item row moved to
  `_course-item-row.leaf`, and the action-cell branch on assignment status —
  three arms whose markup was byte-identical — collapsed to one.
