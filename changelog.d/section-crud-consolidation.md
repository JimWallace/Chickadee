### Changed

- **Test-suite section CRUD shares one implementation across published and
  draft.** The create / rename / delete / reorder manifest mutations were
  copy-pasted between `PublishedAssignmentRoutes+SuiteSections` and
  `DraftAssignmentRoutes+Sections`; they now call shared cores
  (`createSuiteSectionCore` / `renameSuiteSectionCore` / `deleteSuiteSectionCore`
  / `reorderSuiteSectionsCore`) in `SuiteEditHelpers`. The handlers keep only
  their setup resolution and redirect target. No behaviour change.

### Fixed

- **Draft section variables now support per-student expressions.** The draft
  section-variables endpoint had drifted from its published sibling: it
  hand-rolled validation and silently dropped any `expressions` the editor sent.
  It now routes through the same `SectionInputsService.apply` path, gaining
  expression support plus the shared validation (reserved-`seed` name,
  cross-scope clash). The save-time expression eval correctly no-ops on a draft
  (no assignment seed yet) and first runs when the assignment is published.
