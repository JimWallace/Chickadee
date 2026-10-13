// APIServer/Helpers/ClientResponse+Body.swift
//
// The one place a Vapor client response body is read. Vapor 5 replaces the
// `ByteBuffer` body with a streaming one, so the callers move with this file
// and not one by one (docs/vapor-5-migration.md).
//
// `scripts/check-vapor5-readiness.sh` fails `format-lint` on a direct
// `content.decode` outside this file and `Request+DecodeContent.swift`.

import Vapor

extension ClientResponse {
    /// The body as UTF-8 text, or nil when the response has no body.
    var bodyText: String? {
        body.map { String(buffer: $0) }
    }

    /// Decodes the body as `type`, by its content type. Async because the
    /// Vapor 5 body streams; every caller already awaits it.
    func decodeContent<T: Decodable>(_ type: T.Type) async throws -> T {
        try content.decode(type)
    }
}
