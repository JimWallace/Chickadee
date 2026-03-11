// APIServer/Middleware/COEPMiddleware.swift
//
// Adds Cross-Origin-Opener-Policy and Cross-Origin-Embedder-Policy headers
// to every response.  These headers enable `SharedArrayBuffer` in browsers,
// which is required by WebR (R WASM kernel) and by Pyodide in certain modes.
//
// Without these headers:
//   • WebR cannot start (SharedArrayBuffer unavailable)
//   • jupyterlite-webr will not function (Issue #77)
//   • The browser WASM runner cannot use WebR for R test scripts
//
// Note: COEP require-corp requires all cross-origin resources (CDN scripts,
// images, etc.) to respond with appropriate CORP/CORS headers.  Pyodide and
// JSZip CDN resources already include these headers.  JupyterLite CDN
// dependencies should be tested after this is enabled.

import Vapor

struct COEPMiddleware: AsyncMiddleware {
    func respond(
        to request: Request,
        chainingTo next: any AsyncResponder
    ) async throws -> Response {
        let response = try await next.respond(to: request)
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
}
