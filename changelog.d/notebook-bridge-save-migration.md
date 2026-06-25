### Changed

- **Notebook editor saves now route through the iframe command bridge.**
  `notebook.js`'s save flushes — `window.chickadeeSaveNotebook` (the idle-logout
  flush) and the pre-read flush in `readNotebookFromJupyterFrame` — now drive
  `docmanager:save` through the `jupyter-iframe-commands` bridge
  (`executeEditorCommand`, bridge-first with a `frame.contentWindow.jupyterapp`
  fallback) instead of poking the cross-frame `jupyterapp` global directly. The
  global is flaky/absent under WebKit's cross-origin-isolated process model, so
  this hardens save persistence in Safari. The bridge probe
  (`notebook-bridge-probe.yml`) now verifies the migrated production path end to
  end. The remaining `jupyterapp` reads (notebook read-back, server reseed,
  readiness probes) need a custom labextension to bridge and stay as-is for now —
  see `docs/jupyterlite-0.8-integration-followups.md`.
