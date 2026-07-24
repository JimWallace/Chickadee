### Fixed

- **R notebook submissions now grade.** A submitted notebook whose R kernelspec
  was dropped or overwritten by the in-browser editor (e.g. saved under the
  Pyodide kernel) was extracted by the worker as Python, so every test on an R
  assignment errored with "No R submission file was found to grade." The
  submission-merge step now adopts the assignment's authoritative kernel from the
  instructor notebook, so grading follows the assignment's language, not the
  editor's. Python assignments are unaffected.
