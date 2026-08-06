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

### Known

- **The vendored kernels are still not on the asset fast path.**
  `/jupyterlite/xeus/` is ~230 MB and the largest asset tree in the app, and a
  kernel boot fetches every package in its environment — ~50 requests, each
  riding the full middleware chain and paying a Fluent session lookup it does
  not need. Putting it on `EditorAssetFastPathMiddleware` was written and
  reverted here: it is the only behavioural server change in this release, and
  WebKit's editor smoke failed deterministically across it while Chromium
  passed. The tree is not only package tarballs — `kernels.json` and each
  `<env>/<kernel>/kernel.json` are fetched during app startup, so
  short-circuiting the chain also skips it for requests made before a kernel
  exists, on the one engine we deliberately serve non-isolated with the
  JupyterLite service worker intercepting fetches. Scoping the prefix to
  `kernel_packages/` is the likely shape; it needs a green WebKit smoke first.

- **The `Atomics.waitAsync` polyfill patch still does not cover the kernel we
  run, and fixing it needs WebKit evidence first.**
  `patch-waitasync-worker.py` rewrites the polyfill's helper worker from a
  `data:` URL — blocked by our CSP (`worker-src 'self' blob:`) — into a `blob:`
  one, and had only ever globbed the pyodide-kernel extension. Retiring Pyodide
  turned up that the **xeus** extension ships the identical unpatched polyfill,
  for both languages. Re-scoping the patch was written, shipped, and reverted
  inside this change: it is the only edit here touching code that solely WebKit
  executes — Chromium has native `Atomics.waitAsync` and never constructs the
  worker — and WebKit's editor smoke failed deterministically with it applied.
  The substitution is faithful (the `data:` URL decodes byte-for-byte to the
  `blob:` body), so the fault is not a mangled worker; a helper worker that
  previously failed CSP now genuinely starts, on one engine only. The script is
  kept, unwired from `build-jupyterlite.sh`, until that is understood.
