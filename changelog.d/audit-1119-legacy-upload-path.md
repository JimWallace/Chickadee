### Removed

- **The orphaned `/testsetups/new` raw-zip upload pair is gone (#1119).**
  Nothing had linked to it since the draft-based new-assignment flow shipped
  (reachable only by direct URL), and it had drifted behind its API twin's
  hardening — no zip-bomb guard, no dependency-graph validation, no
  grading-mode checks. Programmatic uploads go through the hardened
  `POST /api/v1/testsetups`. While here, the pure notebook-JSON helpers
  (`filterNotebook` / `mergeNotebook` / `normalizeNotebookForJupyterLite` /
  `notebookData(for:)` / zip probes) moved out of `TestSetupRoutes.swift`
  into `Helpers/NotebookContentHelpers.swift`.
