import Elementary
import Testing
import VaporTesting

@testable import APIServer

/// `HTMLResponse` must look like a Leaf `View` to the middleware: the same
/// content type, which SecurityHeadersMiddleware keys its no-store and
/// no-compression rules on.
@Suite(.timeLimit(.minutes(1))) struct HTMLResponseTests {

    @Test func itServesHTMLWithTheLeafContentType() async throws {
        let app = try await Application.make(.testing)
        app.get("page") { _ in HTMLResponse { p { "Hi & bye" } } }
        app.get("gone") { _ in HTMLResponse(status: .notFound) { p { "Gone" } } }
        try await withApp(app) { app in
            try await app.testing().test(.GET, "page") { res in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .html)
                #expect(res.body.string == "<p>Hi &amp; bye</p>")
            }
            try await app.testing().test(.GET, "gone") { res in
                #expect(res.status == .notFound)
            }
        }
    }
}
