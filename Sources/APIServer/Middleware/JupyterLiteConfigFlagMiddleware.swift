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

    /// The cookie that opts one browser out of the server-backed drive (#469)
    /// with the value `0`. Any other value, or no cookie, keeps the drive on.
    static let serverDriveCookie = "ck_server_drive"

    /// The PageConfig option the Chickadee extension reads (serverDrive.ts).
    static let serverDriveOption = "chickadeeServerDrive"

    /// True unless this browser opted out with `ck_server_drive=0`.
    /// `Public/notebook.js` (`serverDriveActive`) must read the cookie the same way.
    static func serverDriveEnabled(_ request: Request) -> Bool {
        request.cookies[serverDriveCookie]?.string != "0"
    }

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

        // (3) Server-backed drive (#469) — the default. One browser opts out
        //     with the `ck_server_drive=0` cookie, which falls back to
        //     JupyterLite's IndexedDB drive: a comparison and an escape hatch
        //     while the drive is new. The extension registers its drive only
        //     when this option is set (serverDrive.ts).
        if Self.serverDriveEnabled(request) {
            configData[Self.serverDriveOption] = "true"
            changed = true
        }

        // The served config now varies by engine (SW enablement) and by the
        // server-drive cookie, so every response for this path must mark itself
        // as varying on both — even when nothing changed for this request — or a
        // shared cache could hand one browser's body to another.
        guard changed else {
            let response = try await next.respond(to: request)
            response.headers.add(name: "Vary", value: "User-Agent, Cookie")
            return response
        }

        json["jupyter-config-data"] = configData
        guard let body = try? JSONSerialization.data(withJSONObject: json) else {
            let response = try await next.respond(to: request)
            response.headers.add(name: "Vary", value: "User-Agent, Cookie")
            return response
        }
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        response.headers.replaceOrAdd(name: "Cache-Control", value: "no-cache")
        response.headers.add(name: "Vary", value: "User-Agent, Cookie")
        return response
    }
}
