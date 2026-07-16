// APIServer/Middleware/JupyterLiteConfigFlagMiddleware.swift
//
// Injects the `exposeAppInBrowser` PageConfig flag into the served JupyterLite
// `jupyter-lite.json` config files at request time, instead of baking it into
// the checked-in bundle.
//
// Why not edit the bundle: `Public/jupyterlite` is a verified build artifact —
// `jupyterlite.yml` rebuilds it from `Tools/jupyterlite` and `git diff
// --exit-code`s against the commit, so any hand-edit drifts and fails CI. A
// local rebuild is worse: it risks byte-instability vs CI and could regenerate
// the kernel wheel without the nb_mypy/chdir patch. Injecting the one flag at
// serve time leaves the bundle untouched.
//
// Why the flag matters: with `exposeAppInBrowser` set, JupyterLite assigns
// `window.jupyterapp` in the editor iframe, which lets the notebook page reach
// the app's contents manager from the parent frame and create the per-student
// working-copy directory in the Drive before saving (see notebook.js
// `ensureDriveParentDirectories`). JupyterLite 0.8's `contents.save()` throws
// "Directory does not exist" unless that nested parent dir already exists, and
// nothing else creates it client-side.
//
// Applies to every `*/jupyter-lite.json` under `/jupyterlite/`, so the flag is
// present whichever config the app merges (root + per-app). Best-effort: any
// read/parse/serialize failure falls through to the normal static-file response,
// so a malformed or missing config never turns into a 500.

import Foundation
import Vapor

struct JupyterLiteConfigFlagMiddleware: AsyncMiddleware {
    /// The JupyterLite extension that registers the service worker. Kept disabled
    /// in the checked-in bundle (SharedArrayBuffer-only); re-enabled per-request
    /// for WebKit, whose comlink kernel needs the SW for synchronous stdin/Drive.
    static let serviceWorkerManagerExtension =
        "@jupyterlite/application-extension:service-worker-manager"

    private let publicDirectory: String

    init(publicDirectory: String) {
        self.publicDirectory = publicDirectory.hasSuffix("/") ? publicDirectory : publicDirectory + "/"
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let path = request.url.path
        guard request.method == .GET,
            path.hasPrefix("/jupyterlite/"),
            path.hasSuffix("/jupyter-lite.json"),
            !path.contains("..")
        else {
            return try await next.respond(to: request)
        }

        let absolutePath = publicDirectory + path.dropFirst()  // strip leading "/"
        guard let data = FileManager.default.contents(atPath: absolutePath),
            var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            var configData = json["jupyter-config-data"] as? [String: Any]
        else {
            // Missing file or not a jupyter-lite config we can parse — serve as-is.
            return try await next.respond(to: request)
        }

        var changed = false

        // (1) exposeAppInBrowser — makes `window.jupyterapp` reachable in the
        //     editor iframe so the notebook page can create the per-student Drive
        //     directory before save (JupyterLite 0.8 throws otherwise).
        if configData["exposeAppInBrowser"] == nil {
            configData["exposeAppInBrowser"] = "true"
            changed = true
        }

        // (2) WebKit transport — re-enable the JupyterLite service worker (remove
        //     its manager from `disabledExtensions`) so the non-isolated comlink
        //     kernel has a synchronous stdin/Drive path. Chrome/Edge/Firefox keep
        //     it disabled (SharedArrayBuffer carries sync). See EditorBrowserEngine.
        if EditorBrowserEngine.isWebKit(request),
            var disabled = configData["disabledExtensions"] as? [String],
            let idx = disabled.firstIndex(of: Self.serviceWorkerManagerExtension)
        {
            disabled.remove(at: idx)
            configData["disabledExtensions"] = disabled
            changed = true
        }

        // The served config now varies by engine (SW enablement), so every
        // response for this path must mark itself as varying on the User-Agent —
        // even when nothing changed for this request — or a shared cache could
        // hand a WebKit body to Chrome (or vice versa).
        guard changed else {
            let response = try await next.respond(to: request)
            response.headers.add(name: "Vary", value: "User-Agent")
            return response
        }

        json["jupyter-config-data"] = configData
        guard let body = try? JSONSerialization.data(withJSONObject: json) else {
            let response = try await next.respond(to: request)
            response.headers.add(name: "Vary", value: "User-Agent")
            return response
        }
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-cache")
        response.headers.add(name: "Vary", value: "User-Agent")
        return response
    }
}
