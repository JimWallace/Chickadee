### Removed

- **Dead-code audit sweep.** Removed unreferenced Swift declarations and CSS
  rules found by a repo-wide reachability sweep. Swift: the unused `BaseContext`
  Leaf-context struct, the unused `NotebookLanguage` enum in `RunnerCore`
  (language resolution goes through `Core`'s `AssignmentLanguage`),
  `NotebookCellSources.codeCellSources(_:)`, `BrightSpaceClientRegistry`'s
  `invalidateAll()`, `ServerHealthAlertService.resetForTesting()`,
  `APIUser.setRole(_:)`, and `waitForRunnerValidation(...)` together with the
  `RunnerValidationOutcome` enum that existed only as its return type.
  Stylesheet: 18 class rules and 2 id rules in `Public/styles.css` with no
  remaining markup or JS reference, including `#suite-config-table` (left over
  from the v0.4.79 server-authoritative suite editor) and `#validate-results`.
  No behaviour changes.
