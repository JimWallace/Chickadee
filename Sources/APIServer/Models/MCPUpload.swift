// APIServer/Models/MCPUpload.swift
//
// One staged MCP file upload (docs/mcp-file-uploads.md). `begin_upload` creates
// the row for one agent grant and one course and hands the agent an upload
// URL and a secret token. The agent PUTs the file's bytes to that URL with the
// token as a bearer header, and a write tool
// (`author_script`, `create_dataset`, `add_dataset_version`) then names the row
// by `uploadID`. Using it deletes the row; an unused row expires.
//
// Only the SHA-256 hex digest of the secret token is stored, as for the
// OAuth codes. The row lives on the MAIN (owner) pool: it is grant
// bookkeeping, like `oauth_*`, so the least-privilege `chickadee_mcp` role has
// no grant on it.

import Fluent
import Foundation

final class MCPUpload: Model, @unchecked Sendable {
    // @unchecked Sendable: Fluent's property wrappers are not checkable; the
    // row is read and written within one request.
    static let schema = "mcp_uploads"

    @ID(key: .id)
    var id: UUID?

    /// SHA-256 hex digest of the upload token the PUT presents.
    @Field(key: "token_hash")
    var tokenHash: String

    /// The token subject (username) of the grant that began the upload.
    @Field(key: "subject")
    var subject: String

    /// The OAuth client of that grant; nil for a directly minted service token.
    @OptionalField(key: "client_id")
    var clientID: String?

    /// The course the upload may be used in.
    @Field(key: "course_id")
    var courseID: UUID

    @Field(key: "expires_at")
    var expiresAt: Date

    /// The file's bytes, nil until the PUT arrives.
    @OptionalField(key: "bytes")
    var bytes: Data?

    @OptionalField(key: "sha256")
    var sha256: String?

    @OptionalField(key: "uploaded_at")
    var uploadedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, tokenHash: String, subject: String, clientID: String?, courseID: UUID, expiresAt: Date) {
        self.id = id
        self.tokenHash = tokenHash
        self.subject = subject
        self.clientID = clientID
        self.courseID = courseID
        self.expiresAt = expiresAt
    }
}
