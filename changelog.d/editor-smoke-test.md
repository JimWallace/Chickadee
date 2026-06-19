### Added

- **Pre-merge headless-browser smoke test for the notebook editor.** A new
  Playwright harness (`Tools/editor-smoke-test/`) boots the real
  `chickadee-server` and drives the JupyterLite editor in headless Chromium,
  asserting the Pyodide kernel actually comes up and runs a cell (`7*191` →
  `1337`) with no blocked-resource errors. This is the gate the recent editor
  breakages slipped through: `swift test`, the render tests, and the
  `BrowserRunnerJSTests` only prove code/templates *resolve* — none put a
  browser in front of the editor, so the COEP cross-origin-isolation attempt
  that blocked the Pyodide kernel worker passed CI and only failed in front of a
  student. The harness is verified to catch exactly that regression: its
  `selftest.sh` fails unless the editor passes on the default config **and**
  fails under `NOTEBOOK_CROSS_ORIGIN_ISOLATION=true` (which reproduces the
  blocked worker), so the guard can't silently rot. Wired into CI as a new
  `Editor smoke test` workflow that runs nightly and per-PR (path-filtered to
  the notebook/editor/middleware/asset files that can break the editor);
  advisory for now. See `docs/notebook-editor-smoke-test.md`.
