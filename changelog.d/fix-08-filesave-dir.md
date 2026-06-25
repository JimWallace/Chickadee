### Fixed

- **In-browser notebook save on JupyterLite 0.8 ("Directory does not exist").**
  0.8's `@jupyterlite/contents` `save()` requires the notebook's parent directory
  to already be a materialized directory entry in the browser Drive (0.7.x
  auto-created intermediate dirs). Chickadee working copies are nested under
  `users/<uid>/<setup>/`, which nothing created client-side, so the first save —
  and the editor's own Ctrl-S — threw `Directory does not exist` and students
  could lose work. The notebook page now creates the ancestor directories in the
  Drive before seeding (`ensureDriveParentDirectories`), and a new
  `JupyterLiteConfigFlagMiddleware` injects the `exposeAppInBrowser` PageConfig
  flag into the served `jupyter-lite.json` configs so the in-iframe app/contents
  manager is reachable to do it (the flag is injected at serve time rather than
  baked into the verified, rebuilt-and-diffed bundle). No bundle rebuild required.
