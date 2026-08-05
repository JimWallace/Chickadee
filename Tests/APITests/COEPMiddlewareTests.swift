import Fluent
import Testing
import VaporTesting

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
        app.get("instructor", ":assignmentID", "workbench") { _ in "workbench" }
        app.get("instructor", ":assignmentID", "edit") { _ in "edit" }
        app.get("jupyterlite", "notebooks", "index.html") { _ in "iframe" }
        app.get("python-grading-worker.js") { _ in "// python grading worker" }
        app.get("r-grading-worker.js") { _ in "// r grading worker" }
        app.get("freeze-watchdog-worker.js") { _ in "// freeze worker" }
        app.get("pyodide-worker.js") { _ in "// pyodide worker" }
        app.get("plain") { _ in "plain" }

        return app
    }

    // MARK: - Flag OFF (default) preserves the long-standing behaviour

    @Test func notebookPageIsNotIsolatedByDefault() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/testsetups/setup_123/notebook") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    @Test func jupyterliteAssetsAreNotIsolatedByDefault() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/notebooks/index.html") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Resource-Policy") == nil)
            }
        }
    }

    // MARK: - Flag ON isolates the editor page AND its iframe assets

    @Test func notebookPageIsIsolatedWhenEnabled() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(.GET, "/testsetups/setup_123/notebook") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            }
        }
    }

    @Test func jupyterliteAssetsAreIsolatedWhenEnabled() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(.GET, "/jupyterlite/notebooks/index.html") { res async in
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
            try await app.testing().test(.GET, "/instructor/assignment_123/validate") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            }
        }
    }

    @Test func unrelatedPageNeverReceivesCOEPHeaders() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(.GET, "/plain") { res async in
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
            for path in [
                "/python-grading-worker.js", "/r-grading-worker.js", "/freeze-watchdog-worker.js",
            ] {
                try await app.testing().test(.GET, path) { res async in
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
            try await app.testing().test(.GET, "/pyodide-worker.js") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    @Test func workerScriptsAreNotIsolatedWhenDisabled() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/python-grading-worker.js") { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    // MARK: - WebKit gets the NON-isolated comlink + service-worker transport
    //
    // The kernel deadlocks on the SharedArrayBuffer/`coincident` path on WebKit,
    // so a WebKit User-Agent must NOT be cross-origin isolated even when the
    // editor is enabled. Chrome/Edge/Firefox keep the isolated path. The
    // responses also carry `Vary: User-Agent` so a shared cache can't hand one
    // engine's body to the other. See EditorBrowserEngine.

    private static let safariUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 "
        + "(KHTML, like Gecko) Version/18.2 Safari/605.1.15"
    private static let chromeUA =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36"

    private func variesOnUserAgent(_ res: TestingHTTPResponse) -> Bool {
        res.headers["Vary"].contains { $0.contains("User-Agent") }
    }

    @Test func notebookPageIsNotIsolatedForWebKit() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(
                .GET, "/testsetups/setup_123/notebook",
                headers: ["User-Agent": Self.safariUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
                #expect(self.variesOnUserAgent(res))
            }
        }
    }

    @Test func notebookPageStaysIsolatedForChrome() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(
                .GET, "/testsetups/setup_123/notebook",
                headers: ["User-Agent": Self.chromeUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
                #expect(self.variesOnUserAgent(res))
            }
        }
    }

    @Test func iframeAssetsAreNotIsolatedForWebKit() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(
                .GET, "/jupyterlite/notebooks/index.html",
                headers: ["User-Agent": Self.safariUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    @Test func iframeAssetsStayIsolatedForChrome() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(
                .GET, "/jupyterlite/notebooks/index.html",
                headers: ["User-Agent": Self.chromeUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
            }
        }
    }

    @Test func validatePageIsNotIsolatedForWebKit() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .GET, "/instructor/assignment_123/validate",
                headers: ["User-Agent": Self.safariUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    // MARK: - Assignment workbench: the whole ancestor chain must be isolated

    // Cross-origin isolation is a property of the entire frame chain.  If the
    // workbench is not isolated, the JupyterLite editor iframe cannot be either
    // — `crossOriginIsolated` goes false inside it and the kernel silently
    // drops off SharedArrayBuffer onto the service-worker transport, with no
    // error anywhere.
    //
    // #1266 merged the workbench into one document, so the chain is one link
    // shorter: there is no `…/workbench/panel` wrapper to isolate any more.
    // The requirement on the workbench itself is unchanged, and these two tests
    // are the only place it is stated executably.

    @Test(arguments: [
        "/instructor/assignment_123/workbench"
    ])
    func workbenchChainIsIsolatedForChrome(path: String) async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(
                .GET, path, headers: ["User-Agent": Self.chromeUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == "same-origin")
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == "require-corp")
                #expect(variesOnUserAgent(res), "Isolation varies by engine, so the response must Vary")
            }
        }
    }

    @Test(arguments: [
        "/instructor/assignment_123/workbench"
    ])
    func workbenchChainIsNotIsolatedForWebKit(path: String) async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(
                .GET, path, headers: ["User-Agent": Self.safariUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }

    /// The regression that matters most: the workbench rule must not widen to
    /// the rest of `/instructor/*`.  The standalone edit page is reached by
    /// every instructor on every assignment and has no business being isolated.
    @Test func plainEditPageStaysUnisolated() async throws {
        try await withApp(try await makeApp(isolateNotebook: true)) { app in
            try await app.testing().test(
                .GET, "/instructor/assignment_123/edit", headers: ["User-Agent": Self.chromeUA]
            ) { res async in
                #expect(res.status == .ok)
                #expect(res.headers.first(name: "Cross-Origin-Opener-Policy") == nil)
                #expect(res.headers.first(name: "Cross-Origin-Embedder-Policy") == nil)
            }
        }
    }
}
