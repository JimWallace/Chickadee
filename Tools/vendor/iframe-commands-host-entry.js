// Single entry point for Chickadee's jupyter-iframe-commands host bridge.
//
// Bundled into Public/vendor/iframe-commands-host.js by scripts/setup-vendor.sh
// (esbuild, ESM, comlink folded in).  notebook.js dynamically imports this
// bundle to talk to the `jupyter-iframe-commands` labextension running INSIDE
// the editor iframe (federated into the JupyterLite bundle via
// Tools/jupyterlite/requirements.txt), replacing the fragile
// `frame.contentWindow.jupyterapp.commands.execute(...)` cross-frame poking
// with the extension's supported postMessage/comlink command bridge.
//
// `createBridge({ iframeId })` returns a proxy exposing `.ready` (resolves when
// the in-iframe extension signals it is up), `.execute(command, args)`, and
// `.listCommands()`.  Adding a new export: extend this file, re-run the setup
// script.

export { createBridge, createProxy } from "jupyter-iframe-commands-host";
