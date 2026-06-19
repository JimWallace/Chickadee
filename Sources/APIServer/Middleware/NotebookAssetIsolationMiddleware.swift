// APIServer/Middleware/NotebookAssetIsolationMiddleware.swift
//
// Stamps cross-origin-isolation headers on the JupyterLite iframe assets so the
// iframe document — where the Pyodide kernel and its worker actually run — is
// cross-origin isolated, giving the kernel `SharedArrayBuffer` for synchronous
// execution. `COEPMiddleware` isolates the parent notebook page; this isolates
// the embedded `/jupyterlite/*` documents and assets so the chain is consistent
// (a cross-origin-isolated iframe requires a cross-origin-isolated embedder and
// its own COEP).
//
// Must be registered BEFORE `FileMiddleware`, which serves `/jupyterlite/*` and
// short-circuits the responder chain (it returns without calling `next`), so a
// middleware registered AFTER it never sees those static responses. Registered
// before, this one decorates the response on the way back out.
//
// Gated by `NOTEBOOK_CROSS_ORIGIN_ISOLATION` (off by default): when disabled it
// is a pure pass-through, preserving the long-standing behaviour of serving the
// JupyterLite assets without COEP. See `COEPMiddleware` for the rationale and
// the #574 history.
//
// `Cross-Origin-Resource-Policy: same-origin` is added so the same-origin
// parent can embed these documents/assets under its own COEP; `require-corp`
// itself only constrains cross-origin subresources, which Chickadee does not
// load (Pyodide / CodeMirror / jszip are vendored same-origin).

import Vapor

struct NotebookAssetIsolationMiddleware: AsyncMiddleware {
    /// Whether to apply cross-origin-isolation headers. When false this
    /// middleware does nothing.
    let enabled: Bool

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        guard enabled, request.url.path.hasPrefix("/jupyterlite/") else { return response }

        response.headers.replaceOrAdd(name: "Cross-Origin-Opener-Policy", value: "same-origin")
        response.headers.replaceOrAdd(name: "Cross-Origin-Embedder-Policy", value: "require-corp")
        response.headers.replaceOrAdd(name: "Cross-Origin-Resource-Policy", value: "same-origin")
        return response
    }
}
