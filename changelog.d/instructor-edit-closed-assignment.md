### Added

- **"Save to assignment" in the notebook editor.** Course staff (TA+) can now
  write the notebook they are editing in the embedded JupyterLite editor back to
  the assignment, from the browser — the starter notebook and the reference
  solution both. Previously JupyterLite kept the live document in the browser
  and the only ways to change an assignment's notebooks were an upload on the
  new-assignment page or the MCP `update_notebook` / `update_solution` tools;
  the editor's Edit button was effectively a scratchpad. The new endpoint
  (`POST /testsetups/:id/notebook/save`) reuses those tools' server-side steps,
  is versioned like every other authoring write, and re-runs validation — but,
  matching the other live-edit endpoints rather than the MCP tools, it never
  changes the assignment's visibility, so fixing a starter notebook mid-lab does
  not close the assignment out from under students.

### Fixed

- **Course staff can edit an assignment's notebooks while it is closed.** The
  notebook editor locked itself read-only ("This assignment is closed — view
  only") for everyone on a closed assignment, including the staff authoring it —
  and an assignment is closed for exactly the window in which it is being
  written, since creating, cloning, or saving one returns it to closed. Staff
  (TA+ or admin in the assignment's course) now keep an editable starter and
  solution notebook regardless of the closed state; students are unaffected, and
  submission stays gated by the closed state for everyone.
