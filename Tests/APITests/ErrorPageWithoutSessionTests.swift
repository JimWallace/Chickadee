import Testing
import VaporTesting

@testable import APIServer

/// An error can be thrown before SessionsMiddleware runs. The error page must
/// still render, with no CSRF token and no session cookie: reading the session
/// there traps in a debug build.
@Suite(.timeLimit(.minutes(1))) struct ErrorPageWithoutSessionTests {

    @Test func anErrorBeforeTheSessionMiddlewareRendersThePageWithNoToken() async throws {
        let app = try await Application.make(.testing)
        app.middleware.use(ErrorPageMiddleware())
        app.get("missing") { _ -> String in throw Abort(.notFound) }
        try await withApp(app) { app in
            try await app.testing().test(.GET, "missing") { res in
                #expect(res.status == .notFound)
                #expect(res.headers.contentType == .html)
                #expect(res.headers.setCookie?["vapor-session"] == nil)
                #expect(res.body.string.contains(#"<meta name="csrf-token" content="">"#))
                #expect(res.body.string.contains("404"))
            }
        }
    }
}
