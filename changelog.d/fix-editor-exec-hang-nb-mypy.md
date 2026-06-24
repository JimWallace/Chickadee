### Changed

- **Disabled nb_mypy in-editor type-checking.** The bundled nb_mypy type checker
  registered an IPython `pre_run_cell` hook that ran a full, synchronous,
  compiled-WASM `mypy.api.run(...)` before *every* cell on the kernel's single
  thread — a real per-cell cost. It is now **disabled**
  (`scripts/patch-pyodide-kernel.py` injects no activation; the nb_mypy / mypy /
  astor wheels stay vended so re-enabling is a one-line change). In-editor mypy
  type warnings are gone until type-checking is reworked as a non-blocking
  background / language-server check that never runs on the cell-execute path.
  **Note:** nb_mypy was initially suspected as the cause of the editor
  `exec_hang`, but a controlled test (stripped wheel, still hung 8/8) disproved
  that — the hang persists and is under separate investigation (see
  `docs/exec-hang-investigation.md`).
