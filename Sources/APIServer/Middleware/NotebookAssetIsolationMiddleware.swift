// APIServer/Middleware/NotebookAssetIsolationMiddleware.swift
//
// Stamps cross-origin-isolation headers on the SLOW-PATH `/jupyterlite/*`
// responses — the JupyterLite editor HTML documents (`repl/`, `lab/`,
// `notebooks/` index.html and the like) that FileMiddleware serves — so the
// iframe document where the Pyodide kernel runs is cross-origin isolated,
// giving the kernel `SharedArrayBuffer` for synchronous execution.
// `COEPMiddleware` isolates the parent notebook page.
//
// It ALSO stamps COEP on the app's own Web Worker scripts that an isolated page
// spawns (`/grading-worker.js`, `/freeze-watchdog-worker.js`) — see
// `isolatedWorkerScripts`. Without COEP on the worker script, a `require-corp`
// page cannot spawn the worker at all (Chrome `ERR_BLOCKED_BY_RESPONSE`), which
// would break browser grading + the freeze failover on the notebook page.
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
// `enabled` is set unconditionally at the bootstrap call site (editor isolation
// is no longer behind a flag); the parameter is kept as a unit-test seam, and
// when false this middleware is a pure pass-through. See `COEPMiddleware` for
// the rationale and the #574 history.

import Vapor

struct NotebookAssetIsolationMiddleware: AsyncMiddleware {
    /// Whether to apply cross-origin-isolation headers. When false this
    /// middleware does nothing.
    let enabled: Bool

    /// App-owned Web Worker scripts (served from the Public root, NOT under the
    /// fast path) that are spawned via `new Worker(...)` from a cross-origin-
    /// ISOLATED page (the student notebook page `/testsetups/:id/notebook`). A
    /// dedicated worker created by a `require-corp` document must ITSELF be served
    /// with COEP `require-corp`, or Chrome refuses the worker script with
    /// `ERR_BLOCKED_BY_RESPONSE` — the same rule that blocked the kernel worker
    /// chunk, but for our own workers. The global `SecurityHeadersMiddleware`
    /// gives them CORP but never COEP, so without this they are blocked.
    ///
    /// Deliberately EXCLUDES `/pyodide-worker.js`: it is spawned only by the
    /// assignment-editor pages, which are NOT cross-origin isolated, so it must
    /// not be forced `require-corp`. If an isolated page is ever made to spawn it,
    /// add it here — the editor-smoke worker-spawn probe will flag the regression.
    static let isolatedWorkerScripts: Set<String> = [
        "/grading-worker.js",  // browser submission grader (browser-runner.js)
        "/freeze-watchdog-worker.js",  // main-thread freeze failover (notebook.js)
    ]

    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
        let path = request.url.path
        guard enabled, path.hasPrefix("/jupyterlite/") || Self.isolatedWorkerScripts.contains(path)
        else { return response }
        // Editor compat mode: this client opted out of cross-origin isolation
        // (the COEP `data:`-worker block), so leave its editor iframe documents
        // and worker scripts non-isolated — the kernel uses the service-worker
        // sync path that notebook.js re-registers in compat mode. The vendored
        // asset trees on EditorAssetFastPathMiddleware keep their headers (a
        // COEP-stamped worker script still loads fine from a non-isolated page).
        if request.editorCompatModeRequested { return response }

        response.setCrossOriginIsolationHeaders()
        return response
    }
}
