import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// JupyterLiteConfigFlagMiddleware injects `exposeAppInBrowser: "true"` into the
/// served JupyterLite `jupyter-lite.json` configs WITHOUT touching the checked-in
/// bundle (a verified build artifact). The flag makes `window.jupyterapp`
/// reachable in the editor iframe so the notebook page can create the per-student
/// working-copy directory in the Drive before save (JupyterLite 0.8's
/// `contents.save()` throws "Directory does not exist" otherwise). Pins:
///   1. the flag is injected into both the root and per-app configs;
///   2. an existing value is never overwritten;
///   3. a config without `jupyter-config-data` (or a non-config path) falls
///      through to the static file untouched — never a 500.
@Suite final class JupyterLiteConfigFlagMiddlewareTests {
    private let publicDir: String
    private let tempRoot: String

    init() throws {
        tempRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jlcfg-\(UUID().uuidString)").path
        publicDir = tempRoot + "/Public/"
        let fixtures: [(String, String)] = [
            (
                "jupyterlite/jupyter-lite.json",
                #"{"jupyter-config-data":{"appName":"JupyterLite","defaultKernelName":"python"}}"#
            ),
            (
                "jupyterlite/notebooks/jupyter-lite.json",
                #"{"jupyter-lite-schema-version":0,"jupyter-config-data":{"appUrl":"/notebooks"}}"#
            ),
            (
                "jupyterlite/already/jupyter-lite.json",
                #"{"jupyter-config-data":{"exposeAppInBrowser":"false"}}"#
            ),
            ("jupyterlite/weird/jupyter-lite.json", #"{"no-config-here":true}"#),
            ("jupyterlite/other.json", #"{"jupyter-config-data":{"x":1}}"#),
        ]
        for (relativePath, contents) in fixtures {
            let absolute = publicDir + relativePath
            try FileManager.default.createDirectory(
                atPath: (absolute as NSString).deletingLastPathComponent,
                withIntermediateDirectories: true)
            try contents.write(toFile: absolute, atomically: true, encoding: .utf8)
        }
    }

    deinit { try? FileManager.default.removeItem(atPath: tempRoot) }

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(JupyterLiteConfigFlagMiddleware(publicDirectory: publicDir))
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))
        return app
    }

    private func configData(_ res: TestingHTTPResponse) -> [String: Any] {
        let obj = (try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8))) as? [String: Any]
        return (obj?["jupyter-config-data"] as? [String: Any]) ?? [:]
    }

    @Test func injectsFlagIntoRootConfig() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/jupyter-lite.json") { res async in
                #expect(res.status == .ok)
                let cfg = self.configData(res)
                #expect(cfg["exposeAppInBrowser"] as? String == "true")
                #expect(cfg["defaultKernelName"] as? String == "python")  // existing keys preserved
            }
        }
    }

    @Test func injectsFlagIntoPerAppConfig() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/notebooks/jupyter-lite.json") { res async in
                #expect(res.status == .ok)
                let cfg = self.configData(res)
                #expect(cfg["exposeAppInBrowser"] as? String == "true")
                #expect(cfg["appUrl"] as? String == "/notebooks")
            }
        }
    }

    @Test func doesNotOverrideExistingValue() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/already/jupyter-lite.json") { res async in
                #expect(res.status == .ok)
                #expect(self.configData(res)["exposeAppInBrowser"] as? String == "false")  // left as-is
            }
        }
    }

    @Test func fallsThroughWhenNoConfigData() async throws {
        try await withApp(try await makeApp()) { app in
            // No jupyter-config-data → served as-is by FileMiddleware, never a 500.
            try await app.testing().test(.GET, "/jupyterlite/weird/jupyter-lite.json") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("no-config-here"))
                #expect(res.body.string.contains("exposeAppInBrowser") == false)
            }
        }
    }

    @Test func leavesNonJupyterLiteJsonUntouched() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/other.json") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("exposeAppInBrowser") == false)
            }
        }
    }
}
