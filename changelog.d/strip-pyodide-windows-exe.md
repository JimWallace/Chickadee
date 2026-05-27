### Security

- **Drop the Windows `python.exe` bundled in the Pyodide 0.29.x distribution.**
  The upstream Pyodide tarball ships a native Windows executable at the dist
  root that nothing in Chickadee runs — the server, runner, and browser all
  serve `Public/pyodide/` as static WASM assets. It was built with a Go stdlib
  carrying CVE-2025-68121, which tripped the release-build Trivy scan. The file
  is removed and `scripts/setup-vendor.sh` now strips any `*.exe` after
  vendoring so a future Pyodide bump can't reintroduce it.
