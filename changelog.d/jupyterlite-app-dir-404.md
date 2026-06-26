### Fixed

- **Opening a notebook no longer 404s in a stray new tab.** JupyterLite
  (Notebook 7) opens documents at canonical URLs like
  `/jupyterlite/notebooks?path=…` with no `/index.html`, assuming the host
  rewrites an app directory to its index (a real Jupyter server, or an nginx
  `try_files`). Chickadee's static file serving didn't, so those URLs 404'd —
  most visibly when the editor opened a notebook in a new browser tab (all
  engines). A new `JupyterLiteAppIndexMiddleware` redirects the JupyterLite app
  directories (`lab`, `notebooks`, `tree`, `edit`, `consoles`, `repl`) to their
  `index.html`, preserving the query string. The in-iframe editor was unaffected
  either way (it already loads `…/index.html`).
