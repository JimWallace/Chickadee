### Removed

- **The JupyterLite source maps.** The 274 `.map` files under
  `Public/jupyterlite/build/` (48 MB) are gone, and `build-jupyterlite.sh`
  deletes them after each build. Nothing read them. They were served to the
  public, copied into every image and rewritten by each JupyterLite bump.

### Changed

- **The runner wasm build tools are pinned.** `build-runner-wasm.sh` runs
  `esbuild@0.28.2` and `wasm-opt@1.4.0` (binaryen 112), not the newest release,
  and the vendor job checks swiftly 1.2.0 by SHA-256. The same source now
  builds the same bytes, so a new tool release cannot change the hashed file
  name and make every browser download the module again.
