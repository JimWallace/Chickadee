import Fluent
import Testing
import XCTVapor

@testable import APIServer

@Suite struct COEPMiddlewareTests {

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(COEPMiddleware())

        app.get("testsetups", ":testSetupID", "notebook") { _ in
            "notebook"
        }
        app.get("instructor", ":assignmentID", "validate") { _ in
            "validate"
        }
        app.get("plain") { _ in
            "plain"
        }

        return app
    }

    @Test func notebookPageDoesNotReceiveCOEPHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/testsetups/setup_123/notebook") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    @Test func validatePageStillReceivesCOEPHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/instructor/assignment_123/validate") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            }
        }
    }

    @Test func unrelatedPageDoesNotReceiveCOEPHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/plain") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }
}
