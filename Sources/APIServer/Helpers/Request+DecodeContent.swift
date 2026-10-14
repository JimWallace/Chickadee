// APIServer/Helpers/Request+DecodeContent.swift
//
// The one place a request body is collected or decoded. Vapor 5 makes
// `req.content.decode` async, because its bodies stream, and it has no
// future-returning `body.collect`. Every call site already awaits these
// helpers, so that move changes this file and nothing else
// (docs/vapor-5-migration.md).
//
// `scripts/check-vapor5-readiness.sh` fails `format-lint` on a direct
// `req.content.decode` outside this file.

import Vapor

extension Request {
    /// Decodes the request body as `type`, by its content type.
    func decodeContent<T: Decodable>(_ type: T.Type) async throws -> T {
        try content.decode(type)
    }

    /// Collects a body that is still streaming, with the route's default size
    /// cap, so that a decode before the route's own `.collect` step sees it.
    /// An oversized body fails here as it would at that step. Vapor 5 decodes
    /// from the stream, so this goes away at the move.
    func collectBody() async throws {
        _ = try await body.collect(max: application.routes.defaultMaxBodySize.value).get()
    }
}
