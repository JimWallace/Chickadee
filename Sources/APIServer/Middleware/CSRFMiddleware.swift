// APIServer/Middleware/CSRFMiddleware.swift
//
// Cross-site request forgery protection for the session-backed web routes.
//
// This replaces the `vapor-community/CSRF` package (v3.1.1, revision
// 7ca62d39), which pulled Leaf into the build for a form-field tag that
// Chickadee never used. The token scheme is the package's, unchanged, so a page rendered before a deploy still validates
// after it:
//
// - The session holds a random 16-byte hex secret under `CSRFSecret`.
// - A token is `<salt>-<sha256(salt + "-" + secret)>`, with a fresh 8-byte hex
//   salt for each token.
// - A request is valid when hashing its token's salt with the session secret
//   gives the same token back.
//
// `chickadeeCSRFTokenRetrieval` (CSRFTokenRetrieval.swift) finds the token in
// the request.

import Vapor

struct CSRFMiddleware: AsyncMiddleware {
    /// The methods that change nothing, and so need no token.
    private static let safeMethods: [HTTPMethod] = [.GET, .HEAD, .OPTIONS]

    /// The session key that holds the secret.
    private static let secretKey = "CSRFSecret"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard !Self.safeMethods.contains(request.method) else {
            return try await next.respond(to: request)
        }
        let secret = Self.secret(for: request)
        let token = try await chickadeeCSRFTokenRetrieval(request)
        guard Self.isValid(token, secret: secret) else {
            throw Abort(.forbidden, reason: "Invalid CSRF token.")
        }
        return try await next.respond(to: request)
    }

    /// A new token for the request's session. The session gets a secret if it
    /// has none.
    static func createToken(from request: Request) -> String {
        token(salt: [UInt8].random(count: 8).hexEncodedString(), secret: secret(for: request))
    }

    private static func token(salt: String, secret: String) -> String {
        let digest = SHA256.hash(data: Array("\(salt)-\(secret)".utf8))
        return "\(salt)-\(digest.hexEncodedString())"
    }

    private static func isValid(_ token: String, secret: String) -> Bool {
        guard let salt = token.split(separator: "-", omittingEmptySubsequences: false).first else {
            return false
        }
        let expected = Array(Self.token(salt: String(salt), secret: secret).utf8)
        let given = Array(token.utf8)
        // Compare in constant time, so the time taken tells nothing about how
        // much of the token matched.
        guard given.count == expected.count else { return false }
        return zip(given, expected).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private static func secret(for request: Request) -> String {
        if let secret = request.session.data[secretKey] {
            return secret
        }
        let secret = [UInt8].random(count: 16).hexEncodedString()
        request.session.data[secretKey] = secret
        return secret
    }
}
