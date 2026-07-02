### Changed

- **Faster first cell execute in the notebook editor (WebKit).** Dropped
  `jedi` from the pyodide-kernel boot-install list. The kernel reported "idle"
  (off `kernel_info`, which isn't gated on `this.ready`) while still installing
  jedi/ipython at boot, so a cell run in that window blocked on `await this.ready`
  for the rest of boot — ~16-18s on ~30% of WebKit sessions, the slow-first-execute
  whose tail was the residual production `exec_hang`
  (docs/exec-hang-investigation.md, second issue). jedi backs tab-completion
  only, never cell execution, and IPython's completer degrades cleanly when it is
  absent. Applied as a deterministic post-build patch
  (`scripts/patch-pyodide-defer-jedi.py`). Tradeoff: weaker editor tab-completion.
