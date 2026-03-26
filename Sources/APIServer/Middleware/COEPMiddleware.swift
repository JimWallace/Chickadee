// APIServer/Middleware/COEPMiddleware.swift
//
// Adds Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers
// to responses that still require cross-origin isolation.
//
// Without these headers on the relevant pages:
//   • WebR cannot start (SharedArrayBuffer unavailable)
//   • jupyterlite-webr will not function (Issue #77)
//
// The headers are intentionally scoped to paths that need them rather than
// applied globally.  COEP require-corp forces every cross-origin resource on
// the same page to include a Cross-Origin-Resource-Policy header, which breaks
// CDN imports (e.g. CodeMirror via esm.sh) on pages that don't need
// SharedArrayBuffer (e.g. the assignment editor at /instructor/:id/edit).
//
// Paths that need COEP:
//   /instructor/…/validate — reserved for browser-side validation if a future
//                            runtime requires SharedArrayBuffer again
//
// The student notebook page at /testsetups/… must NOT receive COEP. It embeds
// the bundled JupyterLite app in an iframe, and JupyterLite intentionally runs
// without COEP so its service worker can serve synthetic in-browser filesystem
// responses. Applying COEP to the parent page causes Chromium to block the
// iframe navigation with ERR_BLOCKED_BY_RESPONSE.

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

    /// Returns true for paths whose pages still require cross-origin isolation.
    private func needsCOEP(path: String) -> Bool {
        // Instructor validate page — loads assignment-validate.js (Pyodide).
        // Matched by last path component to avoid affecting /instructor/:id/edit
        // and other instructor pages that load CDN resources.
        let last = path.split(separator: "/").last.map(String.init) ?? ""
        if last == "validate" { return true }
        return false
    }
}
