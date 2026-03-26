import XCTest
import XCTVapor
@testable import chickadee_server

final class COEPMiddlewareTests: XCTestCase {

    private func makeApp() throws -> Application {
        let app = Application(.testing)
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

    func testNotebookPageDoesNotReceiveCOEPHeaders() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.GET, "/testsetups/setup_123/notebook") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertNil(res.headers.first(name: "Cross-Origin-Opener-Policy"))
            XCTAssertNil(res.headers.first(name: "Cross-Origin-Embedder-Policy"))
        }
    }

    func testValidatePageStillReceivesCOEPHeaders() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.GET, "/instructor/assignment_123/validate") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.first(name: "Cross-Origin-Opener-Policy"), "same-origin")
            XCTAssertEqual(res.headers.first(name: "Cross-Origin-Embedder-Policy"), "require-corp")
        }
    }

    func testUnrelatedPageDoesNotReceiveCOEPHeaders() throws {
        let app = try makeApp()
        defer { app.shutdown() }

        try app.test(.GET, "/plain") { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertNil(res.headers.first(name: "Cross-Origin-Opener-Policy"))
            XCTAssertNil(res.headers.first(name: "Cross-Origin-Embedder-Policy"))
        }
    }
}
