// APIServer/LTI/LTIRoutes.swift
//
// Public LTI 1.3 endpoints (docs/lti-1-3.md): the tool key set here, and the
// login and launch in LTIRoutes+Launch.swift.

import Core
import Fluent
import Vapor

struct LTIRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let lti = routes.grouped("lti")
        lti.get("jwks", use: jwks)
        lti.get("login", use: login)
        lti.post("login", use: login)
        lti.post("launch", use: launch)
    }

    /// The tool's public key set. Empty until an admin registers an enabled
    /// platform, so a deployment that does not use LTI never generates or
    /// writes a tool key.
    ///
    /// Sent uncompressed. The server compresses JSON, and for a client that
    /// accepts `deflate` it answers with zlib-wrapped deflate. Brightspace
    /// could not read that body: it fetched the key set, got a 200, and
    /// reported "Keyset URL cannot be reached". The body is under 1 KB, so
    /// compression gains nothing here.
    func jwks(req: Request) async throws -> Response {
        var keys: [JSONValue] = []
        if try await Self.hasEnabledPlatform(on: req.db) {
            let jwk = try await req.application.ltiToolKeyAuthority().publicJWK()
            keys.append(.object(jwk.mapValues { JSONValue.string($0) }))
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        headers.responseCompression = .disable
        let body = try JSONEncoder().encode(JSONValue.object(["keys": .array(keys)]))
        return Response(status: .ok, headers: headers, body: .init(data: body))
    }

    /// True when an admin registered at least one enabled platform. A public
    /// route checks this before it loads the tool key, which is created on
    /// first use, so a deployment that does not use LTI never writes one
    /// (compatibility rule 1; docs/compliance/lti-audit-2026-10.md L-7).
    static func hasEnabledPlatform(on db: any Database) async throws -> Bool {
        try await APILTIPlatform.query(on: db)
            .filter(\.$enabled == true)
            .first() != nil
    }
}
