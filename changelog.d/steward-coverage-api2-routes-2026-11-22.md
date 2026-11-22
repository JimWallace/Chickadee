### Changed

- **More tests for the notebook and JupyterLite contents routes.** The notebook
  routes now have tests for an unknown setup, a reset with no assignment or no
  starter, and the closed gate on the source route. The contents routes now
  have tests for text and base64 file content, folder order, a missing file or
  folder, a path above the drive, a student path that steps out of its folder,
  and an unenrolled student's read-only copy.
