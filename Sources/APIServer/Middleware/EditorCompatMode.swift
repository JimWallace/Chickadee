// APIServer/Middleware/EditorCompatMode.swift
//
// Per-client opt-out of the notebook editor's cross-origin isolation.
//
// The editor is served cross-origin isolated (COOP + COEP) so the Pyodide
// kernel runs on `SharedArrayBuffer` with no service worker — the deterministic
// "Kernel Unknown" fix (docs/notebook-editor-kernel-boot.md).  There is one
// documented residual risk: the pyodide-kernel polyfills `Atomics.waitAsync`
// (on engines that lack it natively, e.g. older Safari / iPadOS) with a
// `new Worker("data:…")`, and `data:` workers are BLOCKED under COEP
// `require-corp`, so on those engines the cross-origin-isolated kernel hangs
// forever with no fallback.
//
// When notebook.js detects that exact combination (`crossOriginIsolated &&
// !Atomics.waitAsync`) it sets the `ck-editor-compat` cookie and reloads.  The
// isolation middlewares (`COEPMiddleware`, `NotebookAssetIsolationMiddleware`)
// then DROP the COEP header for that client, so the editor page + iframe are no
// longer cross-origin isolated.  Without SAB the kernel falls back to the
// JupyterLite service-worker sync path (which notebook.js re-registers in
// compat mode) — the pre-isolation path, which those engines can run.
//
// This is a per-client cookie, so the cross-origin-isolated majority is never
// affected: the default (no cookie) path is unchanged.

import Vapor

enum EditorCompatMode {
    /// Cookie set by notebook.js to request the non-isolated editor.
    static let cookieName = "ck-editor-compat"
}

extension Request {
    /// True when this client has opted into the non-isolated editor compat mode
    /// (it hit, or would hit, the COEP `data:`-worker block).
    var editorCompatModeRequested: Bool {
        cookies[EditorCompatMode.cookieName]?.string == "1"
    }
}
