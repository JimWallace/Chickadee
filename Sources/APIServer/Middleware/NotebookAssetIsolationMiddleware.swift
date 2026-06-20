// APIServer/Middleware/NotebookAssetIsolationMiddleware.swift
//
// Stamps cross-origin-isolation headers on the SLOW-PATH `/jupyterlite/*`
// responses — the JupyterLite editor HTML documents (`repl/`, `lab/`,
// `notebooks/` index.html and the like) that FileMiddleware serves — so the
// iframe document where the Pyodide kernel runs is cross-origin isolated,
// giving the kernel `SharedArrayBuffer` for synchronous execution.
// `COEPMiddleware` isolates the parent notebook page.
//
// NOTE on coverage: the vendored asset *trees* (`/jupyterlite/build/`,
// `/jupyterlite/extensions/` — including the Pyodide kernel WORKER chunk — plus
// `/pyodide/` and `/vendor/`) are served by `EditorAssetFastPathMiddleware`,
// which short-circuits the chain UPSTREAM of this middleware. Those responses
// never reach here, so the fast path isolates them itself (see
// `setCrossOriginIsolationHeaders`). This middleware only catches the
// `/jupyterlite/*` paths NOT on that whitelist (the HTML documents and the
// per-student `/jupyterlite/files/...` copies).
//
// Must be registered BEFORE `FileMiddleware`, which serves the editor HTML and
// short-circuits the responder chain (it returns without calling `next`), so a
// middleware registered AFTER it never sees those static responses. Registered
// before, this one decorates the response on the way back out.
//
// Gated by `NOTEBOOK_CROSS_ORIGIN_ISOLATION` (off by default): when disabled it
// is a pure pass-through, preserving the long-standing behaviour of serving the
// JupyterLite assets without COEP. See `COEPMiddleware` for the rationale and
// the #574 history.

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

        response.setCrossOriginIsolationHeaders()
        return response
    }
}
