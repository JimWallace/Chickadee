import Testing
import VaporTesting

@testable import APIServer

/// `CSRFMiddleware` replaced the `vapor-community/CSRF` package. These tests pin
/// what it must keep: safe methods pass, an unsafe method needs a token from
/// the same session, and the token format is the package's, so a page rendered
/// before the deploy still validates after it.
@Suite(.timeLimit(.minutes(1))) struct CSRFMiddlewareTests {

    /// A session secret that `/seed` writes, as the package would have.
    private static let knownSecret = "00112233445566778899aabbccddeeff"

    private func makeApp() async throws -> Application {
        let app = try await Application.make(.testing)
        app.sessions.use(.memory)
        app.middleware.use(app.sessions.middleware)
        app.get("token") { req in CSRFMiddleware.createToken(from: req) }
        app.get("seed") { req -> String in
            req.session.data["CSRFSecret"] = Self.knownSecret
            return "seeded"
        }
        let protected = app.grouped(CSRFMiddleware())
        protected.get("read") { _ in "read" }
        protected.post("write") { _ in "written" }
        return app
    }

    /// The token and session cookie from one GET of `path`.
    private func fetch(_ path: String, on app: Application) async throws -> (body: String, cookie: String) {
        var body = ""
        var cookie = ""
        try await app.asyncTest(.GET, path) { res in
            body = res.body.string
            let setCookie = try #require(res.headers.first(name: .setCookie))
            cookie = String(setCookie.prefix { $0 != ";" })
        }
        return (body, cookie)
    }

    private func post(
        token: String?, asFormField: Bool = false, cookie: String, on app: Application
    ) async throws -> (status: HTTPStatus, body: String) {
        var result: (HTTPStatus, String) = (.ok, "")
        try await app.asyncTest(
            .POST, "write",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                guard let token else { return }
                if asFormField {
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                } else {
                    req.headers.add(name: "x-csrf-token", value: token)
                }
            },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    @Test func aSafeMethodNeedsNoToken() async throws {
        try await withApp(try await makeApp()) { app in
            try await app.asyncTest(.GET, "read") { res in
                #expect(res.status == .ok)
                #expect(res.body.string == "read")
            }
        }
    }

    @Test func aTokenFromTheSameSessionPassesInAHeader() async throws {
        try await withApp(try await makeApp()) { app in
            let (token, cookie) = try await fetch("token", on: app)
            let result = try await post(token: token, cookie: cookie, on: app)
            #expect(result.status == .ok)
            #expect(result.body == "written")
        }
    }

    @Test func aTokenFromTheSameSessionPassesInTheFormField() async throws {
        try await withApp(try await makeApp()) { app in
            let (token, cookie) = try await fetch("token", on: app)
            let result = try await post(token: token, asFormField: true, cookie: cookie, on: app)
            #expect(result.status == .ok)
        }
    }

    @Test func aMissingTokenIsRefused() async throws {
        try await withApp(try await makeApp()) { app in
            let (_, cookie) = try await fetch("token", on: app)
            let result = try await post(token: nil, cookie: cookie, on: app)
            #expect(result.status == .forbidden)
            #expect(result.body.contains("No CSRF token provided."))
        }
    }

    @Test func aChangedTokenIsRefused() async throws {
        try await withApp(try await makeApp()) { app in
            let (token, cookie) = try await fetch("token", on: app)
            let changed = String(token.dropLast()) + (token.hasSuffix("0") ? "1" : "0")
            let result = try await post(token: changed, cookie: cookie, on: app)
            #expect(result.status == .forbidden)
            #expect(result.body.contains("Invalid CSRF token."))
        }
    }

    @Test func aTokenFromAnotherSessionIsRefused() async throws {
        try await withApp(try await makeApp()) { app in
            let (token, _) = try await fetch("token", on: app)
            let (_, otherCookie) = try await fetch("token", on: app)
            let result = try await post(token: token, cookie: otherCookie, on: app)
            #expect(result.status == .forbidden)
        }
    }

    /// A token in the package's format, made from the session secret, passes.
    /// This is the compatibility promise for pages open during a deploy.
    @Test func aTokenInThePackageFormatPasses() async throws {
        try await withApp(try await makeApp()) { app in
            let (_, cookie) = try await fetch("seed", on: app)
            let salt = "0123456789abcdef"
            let digest = SHA256.hash(data: Array("\(salt)-\(Self.knownSecret)".utf8))
            let token = "\(salt)-\(digest.map { String(format: "%02x", $0) }.joined())"
            let result = try await post(token: token, cookie: cookie, on: app)
            #expect(result.status == .ok)
        }
    }
}
