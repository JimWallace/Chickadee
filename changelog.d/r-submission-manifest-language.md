### Fixed

- **R notebook submissions grade even when the editor rewrote the kernelspec.**
  The worker decided a submission's language (`.R` vs `.py`) from the submitted
  notebook's kernelspec, which the in-browser editor can silently overwrite
  (saving an R notebook under the Pyodide/Python kernel). On a pure-R assignment
  that made every test error with "No R submission file was found to grade" — and
  a submission stored that way could not be recovered by a re-test. The worker is
  now **manifest-authoritative**: for a suite whose graded tests are all R (at
  least one `.R` script, no Python), every notebook submission is extracted to
  `.R` regardless of its kernelspec. Python and mixed-language assignments are
  unaffected.
