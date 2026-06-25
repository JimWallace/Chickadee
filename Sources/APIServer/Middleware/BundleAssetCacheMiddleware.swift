// APIServer/Middleware/BundleAssetCacheMiddleware.swift
//
// Cache discipline for the vended in-browser editor bundle — JupyterLite
// (`/jupyterlite/`) and Pyodide (`/pyodide/`). FileMiddleware serves these with
// an ETag but NO Cache-Control, so browsers fall back to *heuristic* caching and
// can reuse a stale copy for hours without revalidating. That is exactly how the
// exec_hang fix (a changed kernel wheel, same filename) failed to reach
// already-cached students after deploy — the bytes were new on the server, but
// the browser never asked. This middleware makes propagation deterministic.
//
// Two policies, by filename shape:
//   * Content-hashed chunks — `<name>.<hash>.{js,mjs,css,woff,woff2}` with a
//     ≥7-char hex hash segment (the webpack/JupyterLite chunk shape, e.g.
//     `1.f448c86.js`, `remoteEntry.c6732262d69c5d22.js`). The bytes behind such
//     a URL never change — a rebuild mints a new hash → a new URL — so cache
//     immutably for a year. Cheap repeat loads, clean busts.
//   * Everything else — `jupyter-lite.json`, `all.json`, the `*.whl` kernel
//     wheel, `pyodide.asm.wasm`, `pyodide-lock.json`, the entry HTML: a STABLE
//     filename whose content changes on a deploy. `no-cache` = "revalidate
//     before use"; with FileMiddleware's ETag that is a cheap 304 when
//     unchanged, so a deploy propagates on the NEXT page load instead of waiting
//     on the browser's cache heuristics.
//
// Immutable is gated on a cacheable *extension* (never `.json` / `.whl` /
// `.wasm` / `.html`), so a mutable config file can never be frozen by accident —
// the worst a misjudged filename costs is one extra 304. Registered just OUTSIDE
// FileMiddleware (which short-circuits the chain) and skips any response that
// already carries a Cache-Control, so it never overrides a more specific policy.

import Vapor

struct BundleAssetCacheMiddleware: AsyncMiddleware {
    /// Extensions whose content-hashed builds may be cached immutably. Mutable
    /// stable-name assets (`json`, `whl`, `wasm`, `zip`, `html`, …) are absent on
    /// purpose: they always revalidate.
    static let immutableExtensions: Set<String> = ["js", "mjs", "css", "woff", "woff2"]

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        let path = request.url.path
        guard path.hasPrefix("/jupyterlite/") || path.hasPrefix("/pyodide/") else {
            return response
        }
        guard
            request.method == .GET || request.method == .HEAD,
            response.status == .ok || response.status == .notModified,
            response.headers.first(name: .cacheControl) == nil
        else {
            return response
        }

        if Self.isContentHashed(path) {
            response.headers.replaceOrAdd(
                name: .cacheControl, value: "public, max-age=31536000, immutable")
        } else {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        }
        return response
    }

    /// True when the final path component is `<name>.<hash>.<ext>` with a
    /// cacheable extension and a ≥7-char pure-hex hash segment.
    static func isContentHashed(_ path: String) -> Bool {
        guard let filename = path.split(separator: "/").last else { return false }
        let parts = filename.split(separator: ".")
        guard
            parts.count >= 3,
            let ext = parts.last,
            immutableExtensions.contains(ext.lowercased())
        else {
            return false
        }
        let hashSegment = parts[parts.count - 2]
        return hashSegment.count >= 7 && hashSegment.allSatisfy { $0.isHexDigit }
    }
}
