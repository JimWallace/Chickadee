// APIServer/MCP/Transport/MCPUploadRoutes.swift
//
// The upload URL that `begin_upload` hands an agent
// (docs/mcp-file-uploads.md): `PUT /mcp/uploads/<uploadID>` with the file's raw
// bytes as the body and `Authorization: Bearer <uploadToken>`. POST is
// accepted too, for `curl --data-binary`.
//
// The route takes no OAuth bearer and no session. The upload token is the
// credential: 256 bits, minted for one grant and one course, stored only as a
// hash, good for one PUT, and expiring. That keeps the upload a plain `curl`,
// which an agent's shell can run without the OAuth token its MCP client
// holds. The token goes in the header, not the path, because the route logger
// and the request metrics record paths, and both reach the admin diagnostics
// surface. No cookie is read, so the route needs no CSRF token.

import Fluent
import Foundation
import Vapor

struct MCPUploadRoutes: RouteCollection {
    /// The path below the origin, before the upload id.
    static let pathPrefix = "/mcp/uploads/"

    func boot(routes: any RoutesBuilder) throws {
        let body = HTTPBodyStreamStrategy.collect(maxSize: ByteCount(value: MCPUploadService.maxBytes))
        let uploads = routes.grouped("mcp", "uploads")
        uploads.on(.PUT, ":uploadID", body: body, use: receive)
        uploads.on(.POST, ":uploadID", body: body, use: receive)
    }

    struct ReceivedResponse: Content {
        let uploadID: String
        let sizeBytes: Int
        /// The SHA-256 hex digest of the stored bytes, so the agent can check
        /// them against `shasum -a 256` of its local file.
        let sha256: String
    }

    func receive(req: Request) async throws -> ReceivedResponse {
        // A missing or wrong token answers as an unknown upload, so the route
        // says nothing about which ids exist.
        guard let id = req.parameters.get("uploadID").flatMap(UUID.init(uuidString:)),
            let token = req.headers.bearerAuthorization?.token, !token.isEmpty
        else { throw MCPUploadError.unknownUpload }
        let bytes = req.body.data.map { Data($0.readableBytesView) } ?? Data()
        let received = try await MCPUploadService.receive(id: id, token: token, bytes: bytes, on: req.db)
        req.logger.info("mcp.upload.received id=\(received.id) bytes=\(received.sizeBytes)")
        return ReceivedResponse(
            uploadID: received.id.uuidString, sizeBytes: received.sizeBytes, sha256: received.sha256)
    }
}
