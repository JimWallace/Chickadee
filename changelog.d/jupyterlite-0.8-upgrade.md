### Changed

- **Upgraded the in-browser editor to JupyterLite 0.8 / Pyodide 314 / Python
  3.14.** Bumped `jupyterlite`, `jupyterlite-core`, and
  `jupyterlite-pyodide-kernel` to `0.8.0` and re-vendored Pyodide `314.0.0`
  (Pyodide's new Python-aligned versioning; ~510 MB, down from ~1.4 GB on 0.28).
  Two 0.8 integration changes were required and are in place:
  `contentsAllJsonFile: "all.json"` (0.8 gates server-backed contents discovery
  on this PageConfig option) and switching the kernel's `pyodideUrl` to the ESM
  `pyodide.mjs` (0.8's kernel worker loads Pyodide via ESM `import()`, not the
  UMD build). The editor boots, loads notebooks, and grades on 0.8; remaining
  lifecycle hardening is tracked in
  `docs/jupyterlite-0.8-integration-followups.md`. **This upgrade does not fix
  the editor `exec_hang`** — that pre-existing bug survives the version jump and
  is under separate investigation (`docs/exec-hang-investigation.md`).
