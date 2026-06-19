import Fluent
import Testing
import XCTVapor

@testable import APIServer

@Suite struct COEPMiddlewareTests {

    /// Wires both isolation middlewares the way `AppMiddleware` does, with the
    /// `NOTEBOOK_CROSS_ORIGIN_ISOLATION` flag passed through.
    private func makeApp(isolateNotebook: Bool = false) async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(NotebookAssetIsolationMiddleware(enabled: isolateNotebook))
        app.middleware.use(COEPMiddleware(isolateNotebook: isolateNotebook))

        app.get("testsetups", ":testSetupID", "notebook") { _ in "notebook" }
        app.get("instructor", ":assignmentID", "validate") { _ in "validate" }
        app.get("jupyterlite", "notebooks", "index.html") { _ in "iframe" }
        app.get("plain") { _ in "plain" }

        return app
    }

    // MARK: - Flag OFF (default) preserves the long-standing behaviour

    @Test func notebookPageIsNotIsolatedByDefault() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/testsetups/setup_123/notebook") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    @Test func jupyterliteAssetsAreNotIsolatedByDefault() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/jupyterlite/notebooks/index.html") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Resource-Policy") == nil)
            }
        }
    }

    // MARK: - Flag ON isolates the editor page AND its iframe assets

    @Test func notebookPageIsIsolatedWhenEnabled() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testable().test(.GET, "/testsetups/setup_123/notebook") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            }
        }
    }

    @Test func jupyterliteAssetsAreIsolatedWhenEnabled() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testable().test(.GET, "/jupyterlite/notebooks/index.html") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
                #expect(res.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
            }
        }
    }

    // MARK: - Always: validate isolated, unrelated pages untouched

    @Test func validatePageAlwaysReceivesCOEPHeaders() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/instructor/assignment_123/validate") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            }
        }
    }

    @Test func unrelatedPageNeverReceivesCOEPHeaders() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testable().test(.GET, "/plain") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }
}
