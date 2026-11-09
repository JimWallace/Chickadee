import Foundation
import Testing
import VaporTesting

@testable import APIServer

/// The server-backed editor drive (#469) is the default:
/// JupyterLiteConfigFlagMiddleware adds `chickadeeServerDrive: "true"` to the
/// served config unless the browser opts out with `ck_server_drive=0`, and the
/// response varies on the cookie so a shared cache cannot hand one browser's
/// config to another.
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

    @Test(arguments: [nil, "ck_server_drive=1", "other=x"])
    func theServerDriveIsOnByDefault(cookie: String?) async throws {
        try await withApp(try await makeApp()) { app in
            let headers: HTTPHeaders = cookie.map { ["Cookie": $0] } ?? [:]
            let configPath = "/jupyterlite/notebooks/jupyter-lite.json"
            try await app.asyncTest(.GET, configPath, headers: headers) { res async in
                #expect(res.status == .ok)
                #expect(self.configData(res)[JupyterLiteConfigFlagMiddleware.serverDriveOption] as? String == "true")
                #expect(res.headers["Vary"].contains { $0.contains("Cookie") })
            }
        }
    }

    @Test func theOptOutCookieTurnsTheServerDriveOff() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(
                .GET, "/jupyterlite/notebooks/jupyter-lite.json", headers: ["Cookie": "ck_server_drive=0"]
            ) { res async in
                #expect(res.status == .ok)
                #expect(self.configData(res)[JupyterLiteConfigFlagMiddleware.serverDriveOption] == nil)
                #expect(res.headers["Vary"].contains { $0.contains("Cookie") })
            }
        }
    }
}
