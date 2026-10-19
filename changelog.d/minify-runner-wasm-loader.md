### Changed

- **The browser grader loader is minified.** `scripts/build-runner-wasm.sh` now
  runs esbuild with `--minify`. The vendored `Public/runner-wasm/runner-core.js`
  goes from 128,889 to about 58,000 bytes (21,057 to about 14,800 gzip -9). The
  wasm module does not change. The runner-wasm vendor workflow re-vendors the
  loader after the merge.
