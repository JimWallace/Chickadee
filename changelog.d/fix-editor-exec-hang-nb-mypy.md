### Changed

- **Disabled nb_mypy in-editor type-checking.** The bundled nb_mypy type checker
  registered an IPython `pre_run_cell` hook that ran a full, synchronous,
  compiled-WASM `mypy.api.run(...)` before *every* cell on the kernel's single
  thread — a real per-cell cost. It is now **disabled**
  (`scripts/patch-pyodide-kernel.py` injects no activation; the nb_mypy / mypy /
  astor wheels stay vended so re-enabling is a one-line change). In-editor mypy
  type warnings are gone until type-checking is reworked as a non-blocking
  background / language-server check that never runs on the cell-execute path.
  On Python 3.14, nb_mypy's compiled `mypy` dependency is also an ABI risk, so it
  stays off until both issues are addressed. The kernel-startup `os.chdir`
  `exec_hang` fix (v0.4.526) is retained in the same activation block.
  **Note:** nb_mypy was initially suspected as the cause of the editor
  `exec_hang`, but a controlled test (stripped wheel, still hung) disproved that;
  the hang was later root-caused to a kernel `os.chdir` into an unmounted Drive
  folder and fixed in v0.4.526 (see `docs/exec-hang-investigation.md`).
