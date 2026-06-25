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

        guard configData["exposeAppInBrowser"] == nil else {
            return try await next.respond(to: request)  // already set; nothing to do
        }
        configData["exposeAppInBrowser"] = "true"
        json["jupyter-config-data"] = configData

        guard let body = try? JSONSerialization.data(withJSONObject: json) else {
            return try await next.respond(to: request)
        }
        let response = Response(status: .ok, body: .init(data: body))
        response.headers.contentType = .json
        return response
    }
}
