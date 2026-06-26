import Testing
import VaporTesting

@testable import APIServer

/// JupyterLiteAppIndexMiddleware redirects a bare JupyterLite app-directory URL
/// (`/jupyterlite/notebooks?path=…`, which Notebook 7 builds when it opens a
/// document — e.g. in a new tab) to its `index.html`, preserving the query, so
/// the static host serves the app instead of 404ing. Deeper paths and the
/// `index.html` itself are left untouched.
@Suite struct JupyterLiteAppIndexMiddlewareTests {

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.middleware.use(JupyterLiteAppIndexMiddleware())
        // Stand in for FileMiddleware: only the real index.html resolves.
        app.get("jupyterlite", "notebooks", "index.html") { _ in "NOTEBOOKS_INDEX" }
        app.get("jupyterlite", "lab", "index.html") { _ in "LAB_INDEX" }
        return app
    }

    @Test func bareNotebooksDirRedirectsToIndexPreservingQuery() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(
                .GET, "/jupyterlite/notebooks?path=users%2Fx%2Fassignment.ipynb"
            ) { res async in
                #expect(res.status == .temporaryRedirect)
                #expect(
                    res.headers.first(name: "Location")
                        == "/jupyterlite/notebooks/index.html?path=users%2Fx%2Fassignment.ipynb")
            }
        }
    }

    @Test func trailingSlashAlsoRedirects() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/lab/") { res async in
                #expect(res.status == .temporaryRedirect)
                #expect(res.headers.first(name: "Location") == "/jupyterlite/lab/index.html")
            }
        }
    }

    @Test func indexHtmlPassesThrough() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.testing().test(.GET, "/jupyterlite/notebooks/index.html") { res async in
                #expect(res.status == .ok)
                #expect(res.body.string == "NOTEBOOKS_INDEX")
            }
        }
    }

    @Test func deeperPathPassesThrough() async throws {
        try await withApp(try await makeApp()) { app in
            // e.g. /jupyterlite/notebooks/api/contents/… — more than two
            // components, so it is NOT a bare app dir and must fall through.
            try await app.testing().test(.GET, "/jupyterlite/notebooks/api/contents/x") { res async in
                #expect(res.status == .notFound)  // no route → 404, NOT a redirect
            }
        }
    }

    @Test func nonAppDirPassesThrough() async throws {
        try await withApp(try await makeApp()) { app in
            // /jupyterlite/build/… is a vendored asset tree, not an app dir.
            try await app.testing().test(.GET, "/jupyterlite/build/100.abc.js") { res async in
                #expect(res.status == .notFound)
            }
        }
    }
}
