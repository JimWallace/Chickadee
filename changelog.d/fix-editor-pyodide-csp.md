### Fixed

- **In-browser notebook editor could not start its Pyodide kernel.** The
  JupyterLite editor kernel loaded Pyodide from `cdn.jsdelivr.net`, but the
  #574 CSP cleanup dropped that origin from `script-src`/`connect-src`/
  `worker-src` — so as students' cached assets expired the kernel began
  failing with CSP-refused errors.

### Changed

- **Unified on a single canonical Pyodide.** The editor kernel is now served
  the same vendored Pyodide (`/pyodide`) as Chickadee's own browser paths
  (browser-runner grading, `/validate`, setup-edit) via `pyodideUrl` in
  `Tools/jupyterlite/jupyter-lite.json`, instead of fetching a second copy
  from the CDN. The vended version is **derived from the JupyterLite kernel**
  (`scripts/setup-vendor.sh` no longer hardcodes it), so there is one pin, one
  version, and the editor and grader are guaranteed to run the identical
  Python environment. The `cdn.jsdelivr.net` CSP allowance is removed.

### Security

- **Regression guards so this can't recur.** `scripts/check-pyodide-parity.sh`
  fails the build if the vended Pyodide drifts from the kernel's pinned
  version; `scripts/verify-jupyterlite.sh` asserts `pyodideUrl` is same-origin;
  and `cSPHasNoExternalScriptConnectOrWorkerOrigins` asserts the CSP carries no
  third-party script/connect/worker origins. Together they make "editor depends
  on a CDN while the CSP silently drifts" a hard failure.
