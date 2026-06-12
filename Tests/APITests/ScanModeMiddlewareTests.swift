import Fluent
import Testing
import XCTVapor

@testable import APIServer

@Suite struct ScanModeMiddlewareTests {

    private func makeApp(scanEnabled: Bool) async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(
            ScanModeMiddleware(
                configuration: ScanModeConfiguration(enabled: scanEnabled)
            )
        )

        app.post("login") { _ in "login-ok" }
        app.post("api", "v1", "submissions") { _ in "would-submit" }
        app.post("api", "v1", "submissions", "file") { _ in "would-submit-file" }
        app.post("api", "v1", "testsetups") { _ in "would-upload" }
        app.post("instructor", ":id", "retest") { _ in "would-retest" }
        app.post("admin", "users", ":id", "delete") { _ in "would-delete" }
        app.post("admin", "users", ":id", "role") { _ in "would-role-change" }
        app.post("testsetups", ":id", "submit") { _ in "would-submit-browser" }
        app.get("dashboard") { _ in "dashboard" }

        return app
    }

    @Test func gatedRoutesReturn503WhenEnabled() async throws {
        try await withApp(try await makeApp(scanEnabled: true)) { app in
            let gated: [(method: HTTPMethod, path: String)] = [
                (.POST, "/api/v1/submissions"),
                (.POST, "/api/v1/submissions/file"),
                (.POST, "/api/v1/testsetups"),
                (.POST, "/instructor/abc/retest"),
                (.POST, "/admin/users/xyz/delete"),
                (.POST, "/admin/users/xyz/role"),
                (.POST, "/testsetups/setup_42/submit"),
            ]
            for (method, path) in gated {
                try await app.testable().test(method, path) { res async in
                    #expect(
                        res.status == .serviceUnavailable,
                        "expected 503 for \(method.rawValue) \(path), got \(res.status)"
                    )
                    #expect(res.body.string.contains("scan_mode"))
                }
            }
        }
    }

    @Test func nonGatedRoutesStillWorkWhenEnabled() async throws {
        try await withApp(try await makeApp(scanEnabled: true)) { app in
            try await app.testable().test(.POST, "/login") { res async in
                #expect(res.status == .ok)
            }
            try await app.testable().test(.GET, "/dashboard") { res async in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func gatedRoutesPassThroughWhenDisabled() async throws {
        try await withApp(try await makeApp(scanEnabled: false)) { app in
            try await app.testable().test(.POST, "/api/v1/submissions") { res async in
                #expect(res.status == .ok)
            }
            try await app.testable().test(.POST, "/admin/users/x/delete") { res async in
                #expect(res.status == .ok)
            }
        }
    }
}
