### Removed

- **Pyodide is gone — ~465 MB of vendored bytes.** `Public/pyodide`, the
  `jupyterlite-pyodide-kernel` federated extension, `check-pyodide-parity.sh`,
  `add-pyodide-extras.py`, `Tools/vendor/pyodide-extra-packages.json`,
  `patch-pyodide-kernel.py` and the unused nb_mypy/astor wheels are all deleted.
  Both editor kernels and both browser graders have been xeus since v0.5.18; what
  remained was a parity anchor for bytes nothing loaded. `verify-jupyterlite.sh`
  now fails if a `pyodide` federated extension or plugin setting reappears, since
  re-adding the kernel means re-vendoring that payload and restoring its CSP
  allowances.

### Fixed

- **The `Atomics.waitAsync` polyfill patch never covered the kernel we
  actually run.** `patch-pyodide-waitasync-worker.py` rewrites the polyfill's
  helper worker from a `data:` URL — blocked by both our CSP and COEP, hanging
  the kernel on engines without native `waitAsync` (older Safari / iPadOS) — into
  a `blob:` one. It was scoped to the pyodide-kernel extension, and the **xeus**
  extension ships the identical polyfill, unpatched, for both languages. Found
  only because retiring Pyodide meant re-reading the script before deleting it.
  Renamed to `patch-waitasync-worker.py` and scoped to every federated
  extension, with `verify-jupyterlite.sh` asserting the same breadth.

- **Kernel package requests no longer cost a database lookup each.**
  `/jupyterlite/xeus/` — ~230 MB and the largest asset tree in the app — was not
  on `EditorAssetFastPathMiddleware`, so every one of the ~50 package fetches a
  kernel boot makes rode the full middleware chain and paid a Fluent session
  lookup it never needed. That is exactly the class-wide-rush cost the fast path
  exists to remove, and the kernels were the one tree it missed.

### Changed

- **`script-src` keeps `'unsafe-eval'`, and now says why.** Retiring Pyodide was
  expected to allow narrowing it to `'wasm-unsafe-eval'`. Measured with Pyodide
  fully removed, it does not: JupyterLab cannot activate its plugins, the editor
  never renders a console, and restoring `'unsafe-eval'` with no other change
  makes the same smoke pass. JupyterLab compiles JSON-schema validators at run
  time; that is a JupyterLab requirement, not a Pyodide leftover. The comment and
  the migration plan now record the measurement so it is not retried blind.

  The accidental CSP dependency the spike documented — browser Python grading
  working *because* `data:` was absent from `script-src`, which broke Pyodide's
  classic-worker probe — is genuinely gone, since that probe went with Pyodide.
