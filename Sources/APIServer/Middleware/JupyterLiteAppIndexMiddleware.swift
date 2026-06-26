// APIServer/Middleware/JupyterLiteAppIndexMiddleware.swift
//
// Resolves JupyterLite's app entry points when Notebook 7 builds a canonical
// document URL WITHOUT the trailing `/index.html`.
//
// JupyterLite (Notebook 7) opens documents at URLs like
// `/jupyterlite/notebooks?path=…` or `/jupyterlite/lab?path=…` — it is a
// "single-document" app that assumes the host routes an app DIRECTORY to its
// `index.html` (a real Jupyter server, or an nginx `try_files` / SPA rewrite).
// Our static `FileMiddleware` serves files literally, so the bare directory URL
// 404s — most visibly when JupyterLite opens a notebook in a NEW BROWSER TAB
// (`target="_blank"`), which lands on `/jupyterlite/notebooks?path=…` and 404s
// while the original (iframe) editor keeps working. Reproduces on every engine.
//
// This middleware redirects the JupyterLite app directories to their
// `index.html`, preserving the query string, so the app loads — matching the
// SPA-style hosting JupyterLite documents for static hosts. Registered just
// before `FileMiddleware` (which would otherwise 404 the bare directory).
// `/jupyterlite/<app>/index.html` and deeper paths (`…/api/contents/…`) are
// untouched — they already resolve.

import Vapor

struct JupyterLiteAppIndexMiddleware: AsyncMiddleware {
    /// The JupyterLite app entry directories, each of which has an `index.html`.
    static let appDirectories: Set<String> = [
        "lab", "notebooks", "tree", "edit", "consoles", "repl",
    ]

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard request.method == .GET || request.method == .HEAD,
            let path = request.url.path.removingPercentEncoding,
            path.hasPrefix("/jupyterlite/"),
            !path.contains("..")
        else {
            return try await next.respond(to: request)
        }

        // Match exactly `/jupyterlite/<app>` (optionally a trailing slash) — the
        // bare directory URL Notebook 7 builds. A deeper path
        // (`/jupyterlite/notebooks/index.html`, `…/api/contents/…`) has more than
        // two components and falls through to FileMiddleware unchanged.
        let trimmed = path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = trimmed.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "jupyterlite",
            Self.appDirectories.contains(parts[1])
        else {
            return try await next.respond(to: request)
        }

        var target = "/jupyterlite/" + parts[1] + "/index.html"
        if let query = request.url.query, !query.isEmpty {
            target += "?" + query
        }
        return request.redirect(to: target, redirectType: .temporary)
    }
}
