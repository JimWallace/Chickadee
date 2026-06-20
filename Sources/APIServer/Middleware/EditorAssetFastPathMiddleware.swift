// APIServer/Middleware/EditorAssetFastPathMiddleware.swift
//
// Serves the vendored, never-sensitive editor asset trees *before* the
// session middleware chain runs, and stamps immutable cache headers on the
// content-hashed JupyterLite bundle files.
//
// Why this exists: a JupyterLite boot fetches hundreds of static files, and
// FileMiddleware sits at the bottom of the chain — so every one of those
// requests paid a Fluent session lookup (plus idle-timeout / activity
// bookkeeping) it never needed.  Under a class-wide rush that database
// traffic is what pushes the editor's index.html latency up.  This
// middleware short-circuits the chain for asset paths that are vendored
// bytes by construction.
//
// The fast path is a strict prefix WHITELIST, not "/jupyterlite/ minus
// exclusions": `/jupyterlite/files/users/<uuid>/…` (and the lab/notebooks
// variants) serve per-student working copies and MUST keep riding the full
// chain so UserFileNamespaceMiddleware can authenticate the caller.  Only
// trees that contain checked-in vendored content are listed here.
//
// Cache policy:
//   * /jupyterlite/build/ + /jupyterlite/extensions/ files whose name
//     carries a webpack content-hash segment (e.g. `100.5a28c9e.js`,
//     `154.377fd2862adcf65a4294.js`) — the bytes behind a given URL never
//     change; a rebuild produces a new hash → new URL.  Cached immutably
//     for a year, eliminating the per-boot revalidation storm.
//   * Everything else on the fast path (unhashed names like the MathJax
//     fonts, all of /pyodide/, /vendor/) keeps default ETag revalidation:
//     re-vendoring rewrites those bytes IN PLACE under stable names —
//     including the deterministically patched pyodide-kernel wheel — so
//     immutable caching would pin stale bytes across an upgrade (#574's
//     failure class).
//
// On any miss (file absent, traversal attempt, undecodable path) the
// request falls through to the normal chain unchanged, so worst case is
// exactly today's behaviour.

import Vapor

struct EditorAssetFastPathMiddleware: AsyncMiddleware {
    /// Vendored-only trees. Never list a prefix that can contain
    /// user-generated or access-controlled files.
    static let fastPathPrefixes = [
        "/jupyterlite/build/",
        "/jupyterlite/extensions/",
        "/pyodide/",
        "/vendor/",
    ]

    private let publicDirectory: String

    /// When true, the editor asset trees this middleware serves are stamped with
    /// the cross-origin-isolation headers (COOP/COEP/CORP).  Required because the
    /// fast path short-circuits the chain BEFORE `NotebookAssetIsolationMiddleware`,
    /// so without this the isolated editor page would load a kernel worker chunk
    /// that lacks COEP and Chrome would block it.  Gated by
    /// `NOTEBOOK_CROSS_ORIGIN_ISOLATION` (off by default).
    private let crossOriginIsolation: Bool

    init(publicDirectory: String, crossOriginIsolation: Bool = false) {
        self.publicDirectory = publicDirectory.hasSuffix("/") ? publicDirectory : publicDirectory + "/"
        self.crossOriginIsolation = crossOriginIsolation
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method == .GET || request.method == .HEAD,
            let path = request.url.path.removingPercentEncoding,
            !path.contains(".."),
            Self.fastPathPrefixes.contains(where: { path.hasPrefix($0) })
        else {
            return try await next.respond(to: request)
        }

        let absolutePath = publicDirectory + path.dropFirst()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: absolutePath, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return try await next.respond(to: request)
        }

        let response = try await request.fileio.asyncStreamFile(at: absolutePath)
        if Self.isContentHashedBundleAsset(path: path) {
            response.headers.replaceOrAdd(
                name: .cacheControl, value: "public, max-age=31536000, immutable")
        }
        // The slow-path NotebookAssetIsolationMiddleware never sees these
        // short-circuited responses, so the fast path must isolate them itself.
        if crossOriginIsolation {
            response.setCrossOriginIsolationHeaders()
        }
        return response
    }

    /// True for JupyterLite bundle files whose *filename* carries a webpack
    /// content-hash segment — a dot-separated component of 7+ hex characters
    /// (`100.5a28c9e.js`, `154.377fd2862adcf65a4294.js.map`).  Unhashed
    /// names in the same trees (`MathJax_Main-Regular.woff`, `all.json`)
    /// don't match and keep revalidating.
    static func isContentHashedBundleAsset(path: String) -> Bool {
        guard
            path.hasPrefix("/jupyterlite/build/")
                || path.hasPrefix("/jupyterlite/extensions/")
        else {
            return false
        }
        guard let filename = path.split(separator: "/").last else { return false }
        return filename.split(separator: ".").contains { component in
            component.count >= 7
                && component.allSatisfy { $0.isHexDigit && ($0.isNumber || $0.isLowercase) }
        }
    }
}
