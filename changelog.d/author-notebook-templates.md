### Added

- **Course staff author notebooks against the template, not a rendering.** A
  notebook with personalization is two documents: the template the author
  writes (`patients = {{patients}}`) and the per-viewer rendering the server
  produces from it. Staff only ever saw the second one — their own values,
  substituted in — so the placeholders were not visible, not editable, and
  edits to a substituted cell were silently reverted on save (correctly: the
  alternative was baking one person's values into the class template). Staff
  opening the starter or the solution now get the template by default, with
  `{{name}}` standing as written; typing a placeholder into a cell stores it
  verbatim. The two views are separate working copies, so a "View with values"
  switch in the editor toolbar moves between them without either clobbering the
  other's edits, and Submit stays on the rendered view — a template does not
  run. Nothing changes for students, who always get their rendering, or for an
  assignment with no personalization, where the two views are identical bytes.

### Fixed

- **The reference solution was reachable by any enrolled student through
  `/testsetups/:id/notebook/source?file=solution`.** The notebook *page* has
  always gated the solution to course staff — with a comment warning against
  relying on the absence of a UI link — but the raw content endpoint behind it
  never applied the same check, so a student who guessed the query parameter was
  served the answer key as JSON. It now enforces the same staff gate.
