// APIServer/Helpers/Request+DecodeContent.swift
//
// The one place a request body is decoded. Vapor 5 makes
// `req.content.decode` async, because its bodies stream. Every call site
// already awaits this helper, so that move changes this file and nothing
// else (docs/vapor-5-migration.md).
//
// `scripts/check-vapor5-readiness.sh` fails `format-lint` on a direct
// `req.content.decode` outside this file.

import Vapor

extension Request {
    /// Decodes the request body as `type`, by its content type.
    func decodeContent<T: Decodable>(_ type: T.Type) async throws -> T {
        try content.decode(type)
    }
}
