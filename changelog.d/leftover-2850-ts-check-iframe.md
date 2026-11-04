### Changed

- **Every first-party frontend script is type-checked.** `jl-kernel-diagnostics.js` and `jl-cell-perf-patch.js` opt in with `// @ts-check`, with JSDoc only, and their cache-busted tags in the JupyterLite editor are re-patched. `scripts/ts-check-pending.txt` now lists no files (#2850).
