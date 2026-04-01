import XCTest
import XCTVapor
@testable import chickadee_server
import Fluent

final class COEPMiddlewareTests: XCTestCase {

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

    func testNotebookPageDoesNotReceiveCOEPHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/testsetups/setup_123/notebook") { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertNil(res.headers.first(name: "Cross-Origin-Opener-Policy"))
                XCTAssertNil(res.headers.first(name: "Cross-Origin-Embedder-Policy"))
            }
        }
    }

    func testValidatePageStillReceivesCOEPHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/instructor/assignment_123/validate") { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertEqual(res.headers.first(name: "Cross-Origin-Opener-Policy"), "same-origin")
                XCTAssertEqual(res.headers.first(name: "Cross-Origin-Embedder-Policy"), "require-corp")
            }
        }
    }

    func testUnrelatedPageDoesNotReceiveCOEPHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/plain") { res async in
                XCTAssertEqual(res.status, .ok)
                XCTAssertNil(res.headers.first(name: "Cross-Origin-Opener-Policy"))
                XCTAssertNil(res.headers.first(name: "Cross-Origin-Embedder-Policy"))
            }
        }
    }
}
