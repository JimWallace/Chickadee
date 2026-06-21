import Fluent
import Testing
import XCTVapor

@testable import APIServer

@Suite struct COEPMiddlewareTests {

    /// Wires both isolation middlewares the way `AppMiddleware` does (which now
    /// passes `true` unconditionally); the parameter drives both on/off cases.
    private func makeApp(isolateNotebook: Bool = false) async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(NotebookAssetIsolationMiddleware(enabled: isolateNotebook))
        app.middleware.use(COEPMiddleware(isolateNotebook: isolateNotebook))

        app.get("testsetups", ":testSetupID", "notebook") { _ in "notebook" }
        app.get("instructor", ":assignmentID", "validate") { _ in "validate" }
        app.get("jupyterlite", "notebooks", "index.html") { _ in "iframe" }
        app.get("grading-worker.js") { _ in "// grading worker" }
        app.get("freeze-watchdog-worker.js") { _ in "// freeze worker" }
        app.get("pyodide-worker.js") { _ in "// pyodide worker" }
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

    // MARK: - App Web Worker scripts spawned by the isolated notebook page
    //
    // A dedicated worker created by a require-corp page must itself be served
    // with COEP, or the browser blocks the worker (ERR_BLOCKED_BY_RESPONSE) —
    // which silently broke browser grading + the freeze failover.

    @Test func isolatedPageWorkerScriptsReceiveCOEPWhenEnabled() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            for path in ["/grading-worker.js", "/freeze-watchdog-worker.js"] {
                try await app.testable().test(.GET, path) { res async in
                    #expect(res.status == .ok)
                    #expect(
                        res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp",
                        "\(path) must carry COEP so an isolated page can spawn the worker")
                    #expect(
                        res.headers.first(name: "Cross-Origin-Resource-Policy") == "same-origin")
                }
            }
        }
    }

    @Test func pyodideWorkerScriptIsNotForcedIsolated() async throws {
        // /pyodide-worker.js is spawned only by the (non-isolated) assignment
        // editor pages, so it must NOT be forced require-corp.
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testable().test(.GET, "/pyodide-worker.js") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    @Test func workerScriptsAreNotIsolatedWhenDisabled() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testable().test(.GET, "/grading-worker.js") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }
}
