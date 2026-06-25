### Added

- **iframe command bridge prototype (JupyterLite 0.8).** Federate the
  `jupyter-iframe-commands` labextension into the editor bundle and vendor the
  `jupyter-iframe-commands-host` bridge (`Public/vendor/iframe-commands-host.js`),
  the supported replacement for `notebook.js`'s fragile cross-frame
  `frame.contentWindow.jupyterapp.commands` poking. Ships behind a non-required
  CI probe (`notebook-bridge-probe.yml`) that drives `docmanager:save` through
  the bridge on the real editor and asserts it persists; `notebook.js`'s
  production save path is unchanged pending the full cutover. See
  `docs/jupyterlite-0.8-integration-followups.md`.
