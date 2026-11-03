### Changed

- **The xeus kernels are re-vendored to their channels' current builds.**
  The weekly kernel currency check found the vendored kernels behind
  `emscripten-forge-4x`. `.github/workflows/revendor-kernels.yml` rebuilt
  `Public/jupyterlite/` from the unchanged `Tools/jupyterlite/environment-*.yml`
  files and verified it before this pull request was opened.
