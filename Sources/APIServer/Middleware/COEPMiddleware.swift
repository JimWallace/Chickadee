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
//     iframe), when `isolateNotebook` is true (set unconditionally at the
//     bootstrap call site). `NotebookAssetIsolationMiddleware` +
//     `EditorAssetFastPathMiddleware` apply the matching headers to the
//     `/jupyterlite/*` documents and the vendored asset trees so the iframe
//     document — where the kernel worker actually runs — is isolated too.
//
// COEP require-corp only restricts CROSS-origin subresources; same-origin ones
// (Chickadee vendors Pyodide / CodeMirror / jszip same-origin) load unchanged.
//
// History: isolation was gated behind `NOTEBOOK_CROSS_ORIGIN_ISOLATION` while
// the editor was verified to boot under COEP, because COEP on the editor page
// had broken the iframe before (#574). It is now unconditional: the editor's
// SharedArrayBuffer path is verified end-to-end by the editor-smoke harness
// (Tools/editor-smoke-test), and SAB removes the kernel's dependence on the
// service worker for synchronous stdin/Drive — see
// docs/notebook-editor-kernel-boot.md. The `isolateNotebook` parameter is kept
// as a unit-test seam.

import Vapor

struct COEPMiddleware: AsyncMiddleware {
    /// Whether the student notebook editor page opts into cross-origin isolation.
    let isolateNotebook: Bool

    init(isolateNotebook: Bool = false) {
        self.isolateNotebook = isolateNotebook
    }

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

        // Student notebook editor page (/testsetups/:id/notebook), gated.
        if isolateNotebook, parts.count == 3, parts[0] == "testsetups", last == "notebook" {
            return true
        }

        return false
    }
}
