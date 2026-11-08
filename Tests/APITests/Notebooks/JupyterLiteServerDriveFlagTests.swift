import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The `ck_server_drive=1` cookie opts one browser into the server-backed
/// editor drive (#469 spike): JupyterLiteConfigFlagMiddleware adds
/// `chickadeeServerDrive: "true"` to the served config, and the response varies
/// on the cookie so a shared cache cannot hand it to another browser.
@Suite final class JupyterLiteServerDriveFlagTests {
    private let publicDir: String
    private let tempRoot: String

    init() throws {
        tempRoot =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-jldrive-\(UUID().uuidString)").path
        publicDir = tempRoot + "/Public/"
        let config = publicDir + "jupyterlite/notebooks/jupyter-lite.json"
        try FileManager.default.createDirectory(
            atPath: URL(fileURLWithPath: config).deletingLastPathComponent().path, withIntermediateDirectories: true)
        try #"{"jupyter-config-data":{"exposeAppInBrowser":"true"}}"#.write(
            toFile: config, atomically: true, encoding: .utf8)
    }

    deinit { try? FileManager.default.removeItem(atPath: tempRoot) }

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(JupyterLiteConfigFlagMiddleware(publicDirectory: publicDir))
        app.middleware.use(FileMiddleware(publicDirectory: publicDir))
        return app
    }

    private func configData(_ res: TestResponse) -> [String: Any] {
        let object = try? JSONSerialization.jsonObject(with: Data(res.body.string.utf8)) as? [String: Any]
        return object?["jupyter-config-data"] as? [String: Any] ?? [:]
    }

    @Test func theCookieTurnsTheServerDriveOn() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/jupyterlite/notebooks/jupyter-lite.json", headers: ["Cookie": "ck_server_drive=1"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(self.configData(res)[JupyterLiteConfigFlagMiddleware.serverDriveOption] as? String == "true")
                #expect(res.headers["Vary"].contains { $0.contains("Cookie") })
            }
        }
    }

    @Test func withoutTheCookieTheServerDriveStaysOff() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "/jupyterlite/notebooks/jupyter-lite.json") { res async in
                #expect(res.status == .ok)
                #expect(self.configData(res)[JupyterLiteConfigFlagMiddleware.serverDriveOption] == nil)
                #expect(res.headers["Vary"].contains { $0.contains("Cookie") })
            }
        }
    }
}
