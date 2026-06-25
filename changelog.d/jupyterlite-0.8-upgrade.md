### Changed

- **Upgraded the in-browser editor to JupyterLite 0.8 / Pyodide 314 / Python
  3.14.** Bumped `jupyterlite`, `jupyterlite-core`, and
  `jupyterlite-pyodide-kernel` to `0.8.0` and re-vendored Pyodide `314.0.0`
  (Pyodide's new Python-aligned versioning; ~510 MB, down from ~1.4 GB on 0.28).
  Two 0.8 integration changes were required and are in place:
  `contentsAllJsonFile: "all.json"` (0.8 gates server-backed contents discovery
  on this PageConfig option) and switching the kernel's `pyodideUrl` to the ESM
  `pyodide.mjs` (0.8's kernel worker loads Pyodide via ESM `import()`, not the
  UMD build). The kernel-startup `os.chdir` `exec_hang` fix (v0.4.526) applies
  unchanged on 0.8 and is carried into the 0.8 kernel wheel here. The editor
  boots, loads notebooks, and grades on 0.8; the remaining 0.8 blocker — an
  intermittent browser-grading hang on Pyodide 314 — plus the rest of the
  lifecycle hardening are tracked in
  `docs/jupyterlite-0.8-integration-followups.md`.
