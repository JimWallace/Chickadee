// APIServer/Middleware/COEPMiddleware.swift
//
// Adds Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers
// to dynamic (Leaf-rendered) pages that require cross-origin isolation.
//
// Cross-origin isolation (COOP same-origin + COEP require-corp) is what makes
// `SharedArrayBuffer` available, which Pyodide needs to run synchronous Python
// (stdin / filesystem) without blocking the page. Two pages opt in:
//
//   • /instructor/…/validate — browser-side validation (assignment-validate.js).
//   • /testsetups/:id/notebook — the student notebook editor (JupyterLite in an
//     iframe). `NotebookAssetIsolationMiddleware` applies the matching headers
//     to the `/jupyterlite/*` iframe assets so the iframe document — where the
//     kernel worker actually runs — is isolated too. Without this the kernel
//     has no SharedArrayBuffer and (the JupyterLite service worker being
//     disabled) no service-worker sync fallback either, so a synchronous kernel
//     operation hard-freezes the page ("Page Unresponsive").
//
// COEP require-corp only restricts CROSS-origin subresources; same-origin ones
// (Chickadee vendors Pyodide / CodeMirror / jszip same-origin) load unchanged.
// The historical objection — that JupyterLite's service-worker synthesised
// responses lacked CORP — no longer applies: that service worker is disabled.

import Vapor

struct COEPMiddleware: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        guard needsCOEP(path: request.url.path) else { return response }
        response.headers.replaceOrAdd(
            name: "Cross-Origin-Opener-Policy",
            value: "same-origin"
        )
        response.headers.replaceOrAdd(
            name: "Cross-Origin-Embedder-Policy",
            value: "require-corp"
        )
        return response
    }

    /// Returns true for paths whose pages opt into cross-origin isolation.
    private func needsCOEP(path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        let last = parts.last ?? ""

        // Instructor validate page — loads assignment-validate.js (Pyodide).
        // Matched by last path component to avoid affecting /instructor/:id/edit
        // and other instructor pages that load CDN resources.
        if last == "validate" { return true }

        // Student notebook editor page (/testsetups/:id/notebook).
        if parts.count == 3, parts[0] == "testsetups", last == "notebook" {
            return true
        }

        return false
    }
}
