// APIServer/Middleware/COEPMiddleware.swift
//
// Adds Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers
// to responses for paths that use SharedArrayBuffer (Pyodide / WebR).
//
// Without these headers on the relevant pages:
//   • WebR cannot start (SharedArrayBuffer unavailable)
//   • jupyterlite-webr will not function (Issue #77)
//   • The browser WASM runner cannot use WebR for R test scripts
//
// The headers are intentionally scoped to paths that need them rather than
// applied globally.  COEP require-corp forces every cross-origin resource on
// the same page to include a Cross-Origin-Resource-Policy header, which breaks
// CDN imports (e.g. CodeMirror via esm.sh) on pages that don't need
// SharedArrayBuffer (e.g. the assignment editor at /instructor/:id/edit).
//
// Paths that need COEP:
//   /jupyterlite/…   — JupyterLite static files (WASM kernels)
//   /testsetups/…    — student notebook page (browser-runner.js / Pyodide)
//   /instructor/…/validate — validation page (assignment-validate.js / Pyodide)
//
// Note: COEP require-corp requires all cross-origin resources (CDN scripts,
// images, etc.) on scoped pages to respond with appropriate CORP/CORS headers.
// Pyodide and JSZip CDN resources already include these headers.

import Vapor

struct COEPMiddleware: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        guard needsCOEP(path: request.url.path) else { return response }
        response.headers.replaceOrAdd(
            name:  "Cross-Origin-Opener-Policy",
            value: "same-origin"
        )
        response.headers.replaceOrAdd(
            name:  "Cross-Origin-Embedder-Policy",
            value: "require-corp"
        )
        return response
    }

    /// Returns true for paths whose pages load Pyodide, WebR, or JupyterLite
    /// (all of which require `SharedArrayBuffer`).
    private func needsCOEP(path: String) -> Bool {
        // JupyterLite static files and lab UI.
        if path == "/jupyterlite" || path.hasPrefix("/jupyterlite/") { return true }
        // Student notebook submission page — loads browser-runner.js (Pyodide/WebR).
        if path.hasPrefix("/testsetups/") { return true }
        // Instructor validate page — loads assignment-validate.js (Pyodide).
        // Matched by last path component to avoid affecting /instructor/:id/edit
        // and other instructor pages that load CDN resources.
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last == "validate" { return true }
        return false
    }
}
