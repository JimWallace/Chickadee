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
// That bare-directory URL is therefore ONLY ever requested by the stray tab —
// the in-iframe editor always loads `…/index.html`. Rather than redirect it to a
// SECOND full editor (which boots a second kernel and, on WebKit, contends with
// the kernel already running in the iframe), this middleware returns a tiny
// self-closing page: the stray tab was opened by `window.open`, so `window.close()`
// closes it, and it never boots a kernel. (`notebook.js` also suppresses the
// stray `window.open` at the source; this is the server-side backstop.) Registered
// just before `FileMiddleware`; `/jupyterlite/<app>/index.html` and deeper paths
// (`…/api/contents/…`) are untouched — they already resolve, so the iframe editor
// is unaffected.

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

        // Close the stray tab instead of booting a second editor in it. The tab
        // was script-opened by Notebook 7 (`window.open`), so `window.close()` is
        // permitted; the message is the fallback if a browser refuses it.
        let html = """
            <!doctype html>
            <html lang="en">
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <title>Return to your assignment</title>
            </head>
            <body>
            <script>try { window.close() } catch (e) { /* self-close may be blocked; the message below covers it */ }</script>
            <p>This notebook opened in an extra browser tab. You can close this tab and return to your assignment.</p>
            </body>
            </html>
            """
        var headers = HTTPHeaders()
        headers.contentType = .html
        headers.replaceOrAdd(name: .cacheControl, value: "no-store")
        return Response(status: .ok, headers: headers, body: .init(string: html))
    }
}
