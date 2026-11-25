### Changed

- **The xeus kernels are re-vendored to their channels' current builds.**
  `.github/workflows/revendor-kernels.yml` locked the unchanged
  `Tools/jupyterlite/environment-*.yml` files again
  (`Tools/jupyterlite/locks/`), rebuilt `Public/jupyterlite/` from the new
  locks and verified it before this pull request was opened.
