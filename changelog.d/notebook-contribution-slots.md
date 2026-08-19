### Added

- **Contribution slots bound a student's notebook contribution, server-side.**
  A collaborative assignment gives each student a fixed number of places to write
  (three cells, one test each). Enforcing that in the editor cannot work —
  JupyterLite keeps the document in the student's own browser, and notebook mode
  deliberately keeps the upload form open beside it — so the bound is applied
  where every submission already converges: `mergeNotebook` reassembles the
  submitted notebook before it is stored, and now keeps only the slot-marked
  cells, in document order, capped at the count the instructor's starter notebook
  declares. Extra cells are not prevented, they are ignored, which needs no UI
  enforcement and survives an offline-edited upload unchanged. The marker is
  Chickadee-owned cell metadata (`chickadee_slot`), following the
  `chickadee_personalized` precedent, because a first-line comment convention
  breaks the moment a student presses return at the top of a cell. An assignment
  declaring no slots is unaffected — nothing is dropped — so every existing
  notebook assignment goes through this path byte-identical.
