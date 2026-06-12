// APIServer/Middleware/StaticAssetCacheMiddleware.swift
//
// Long-lived caching for version-fingerprinted static assets.
//
// Templates reference shared assets with a cache-buster query derived from
// the running build (`/styles.css?v=#appVersion()` — see AppVersionTag), so
// the URL for a given asset changes on every release.  FileMiddleware serves
// those responses with an ETag but no Cache-Control, leaving the browser to
// revalidate every asset on every page view — a conditional round trip per
// stylesheet/script/icon that also rides the full session middleware chain
// (Fluent session lookup included).  The bytes behind a versioned URL never
// change — a deploy mints a new query string — so responses whose `v`
// matches the running version are cached immutably for a year.
//
// Requests with a stale or absent `v` keep FileMiddleware's default ETag
// revalidation, and responses that already carry a Cache-Control (e.g.
// runner-core.js's `no-cache` from RunnerWasmCacheMiddleware) are left
// untouched.  Registered just OUTSIDE FileMiddleware, which short-circuits
// the chain, so this middleware sees its responses on the way back out.

import Core
import Vapor

struct StaticAssetCacheMiddleware: AsyncMiddleware {
    /// Extensions the templates reference with a `?v=` buster.  Anything
    /// else (HTML pages, dynamic routes) is never stamped.
    static let cacheableExtensions: Set<String> = [
        "css", "js", "mjs", "png", "svg", "ico", "jpg", "jpeg", "webp", "woff", "woff2",
    ]

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        guard
            request.method == .GET || request.method == .HEAD,
            response.status == .ok || response.status == .notModified,
            response.headers.first(name: .cacheControl) == nil,
            Self.isCacheableAssetPath(request.url.path),
            request.query[String.self, at: "v"] == ChickadeeVersion.current
        else {
            return response
        }
        response.headers.replaceOrAdd(
            name: .cacheControl, value: "public, max-age=31536000, immutable")
        return response
    }

    /// True when the path's final component has a cacheable asset extension.
    static func isCacheableAssetPath(_ path: String) -> Bool {
        guard
            let filename = path.split(separator: "/").last,
            filename.contains("."),
            let ext = filename.split(separator: ".").last
        else { return false }
        return cacheableExtensions.contains(ext.lowercased())
    }
}
