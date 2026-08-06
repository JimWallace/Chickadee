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

### Fixed

- **The editor smoke test was booting Pyodide, and said so.** Its default leg
  requested `?kernel=python` — the Pyodide kernelspec — deliberately, because
  its probes were written as pyodide-kernel behaviours. Deleting `Public/pyodide`
  deleted that kernelspec, so every leg asked for a kernel that no longer
  existed. Chromium tolerated it; WebKit did not, and the failure presented as
  a Safari-class editor regression — modal dialog over the console, plugins
  failing to activate — rather than as a stale fixture. The selftest now
  defaults to `xpython`, the editor's actual default and the only Python kernel
  that exists. Both premises behind the old default had expired too: the
  `data:`-worker waitAsync polyfill is not pyodide-specific, and service-worker
  stdin is exactly what xeus does on WebKit.

- **The `Atomics.waitAsync` polyfill patch never covered the kernel we
  actually run.** `patch-pyodide-waitasync-worker.py` rewrites the polyfill's
  helper worker from a `data:` URL — blocked by our CSP (`worker-src 'self'
  blob:`), hanging the kernel on engines without native `waitAsync` (older
  Safari / iPadOS) — into a `blob:` one. It globbed only the pyodide-kernel
  extension, and the **xeus** extension ships the identical polyfill, unpatched,
  for both languages. Retiring Pyodide made this load-bearing rather than merely
  tidy: selftest leg 4 stubs out `Atomics.waitAsync` to force the polyfill path,
  and with the pyodide extension gone the xeus chunks are the only ones left for
  it to exercise. Renamed to `patch-waitasync-worker.py` and scoped to every
  federated extension, with `verify-jupyterlite.sh` asserting the same breadth.
