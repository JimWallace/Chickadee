// APIServer/LTI/LTIRoutes.swift
//
// Public LTI 1.3 endpoints (docs/lti-1-3.md). Slice 1 mounts only the tool
// key set; the login and launch routes come with slice 2.

import Core
import Fluent
import Vapor

struct LTIRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let lti = routes.grouped("lti")
        lti.get("jwks", use: jwks)
    }

    /// The tool's public key set. Empty until an admin registers an enabled
    /// platform, so a deployment that does not use LTI never generates or
    /// writes a tool key.
    func jwks(req: Request) async throws -> Response {
        let hasPlatform =
            try await APILTIPlatform.query(on: req.db)
            .filter(\.$enabled == true)
            .first() != nil
        var keys: [JSONValue] = []
        if hasPlatform {
            let jwk = try await req.application.ltiToolKeyAuthority().publicJWK()
            keys.append(.object(jwk.mapValues { JSONValue.string($0) }))
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        let body = try JSONEncoder().encode(JSONValue.object(["keys": .array(keys)]))
        return Response(status: .ok, headers: headers, body: .init(data: body))
    }
}
