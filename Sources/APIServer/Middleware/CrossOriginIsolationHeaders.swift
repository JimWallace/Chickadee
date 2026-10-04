// APIServer/Middleware/CrossOriginIsolationHeaders.swift
//
// The COOP + COEP + CORP trio that makes a document, dedicated worker, or
// subresource participate in a cross-origin-isolated context — which is what
// gives the xeus kernel `SharedArrayBuffer` for synchronous execution.
//
// Shared by the two middlewares that serve the notebook editor's assets
// (`NotebookAssetIsolationMiddleware` for the slow-path HTML documents,
// `EditorAssetFastPathMiddleware` for the vendored asset trees) so the header
// set cannot drift between them — a drift is exactly what broke the editor: the
// fast-path-served kernel worker chunk was missing COEP, so the isolated editor
// page spawned a worker Chrome then blocked with `ERR_BLOCKED_BY_RESPONSE`.

import Vapor

extension Response {
    /// Stamps `Cross-Origin-Opener-Policy: same-origin`,
    /// `Cross-Origin-Embedder-Policy: require-corp`, and
    /// `Cross-Origin-Resource-Policy: same-origin` on this response.
    ///
    /// All three are required together:
    ///   * COOP `same-origin` + COEP `require-corp` on the editor document make
    ///     it cross-origin isolated (`self.crossOriginIsolated === true`).
    ///   * A dedicated worker the isolated document spawns must ALSO be served
    ///     with COEP `require-corp`, or the worker script load is blocked with
    ///     `ERR_BLOCKED_BY_RESPONSE` — this is the failure the fast path hit.
    ///   * CORP `same-origin` lets the `require-corp` embedder load the resource.
    ///
    /// Idempotent (`replaceOrAdd`): safe to call even though the outer
    /// `SecurityHeadersMiddleware` already sets COOP + CORP globally — this only
    /// adds the COEP the isolated editor paths additionally need.
    func setCrossOriginIsolationHeaders() {
        headers.replaceOrAdd(name: "Cross-Origin-Opener-Policy", value: "same-origin")
        headers.replaceOrAdd(name: "Cross-Origin-Embedder-Policy", value: "require-corp")
        headers.replaceOrAdd(name: "Cross-Origin-Resource-Policy", value: "same-origin")
    }

    /// Isolates this response for the engine that asked for it: the trio
    /// above for every engine but WebKit, which gets no isolation header.
    ///
    /// WebKit deadlocks on the SharedArrayBuffer (`coincident`) kernel
    /// transport, so it must NOT be cross-origin isolated. With COEP off,
    /// `crossOriginIsolated` is false in the iframe and the kernel falls back
    /// to `comlink`; Chrome, Edge and Firefox keep the isolated path. See
    /// `EditorBrowserEngine`. Because the answer varies by engine, the
    /// response always carries `Vary: User-Agent`, so a shared cache keys on
    /// it. The two middlewares that isolate by engine (`COEPMiddleware` for
    /// the pages, `NotebookAssetIsolationMiddleware` for the editor documents
    /// and worker scripts) both call this, so they cannot drift.
    func applyCrossOriginIsolation(for request: Request) {
        headers.add(name: "Vary", value: "User-Agent")
        guard !EditorBrowserEngine.isWebKit(request) else { return }
        setCrossOriginIsolationHeaders()
    }
}
