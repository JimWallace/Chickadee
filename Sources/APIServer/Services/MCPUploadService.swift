// APIServer/Services/MCPUploadService.swift
//
// Staged file uploads for MCP agents (docs/mcp-file-uploads.md). An agent
// cannot pass a large file's exact bytes through a tool call: it would have to
// generate them as tokens. So `begin_upload` returns an upload URL on this
// server and a short-lived secret token, the agent's shell PUTs the file there
// (`curl -T`), and a write tool names the upload by its id.
//
// The secret travels in an `Authorization: Bearer` header, never in the URL:
// the route logger and the request metrics record every path, and both reach
// the admin diagnostics surface. The URL names the upload by its id only.
//
// The rules:
//   - An upload belongs to the grant that began it (token subject plus OAuth
//     client) and to one course. Another grant, or a call in another course,
//     cannot use it.
//   - The URL takes one PUT, of at most `maxBytes`, of UTF-8 text.
//   - The upload is single-use: the write tool deletes it once its write
//     succeeds. A write that fails leaves it, so the agent can fix the call
//     and retry without uploading again.
//   - It expires `lifetime` after `begin`. Expired rows are deleted when the
//     same grant begins another upload, and by the hourly MCP OAuth reaper.
//
// The rows live on the owner pool (`ToolContext.mainDB`); they are grant
// bookkeeping, not course content.

import Core
import Fluent
import Foundation
import SQLKit

enum MCPUploadService {
    /// The same cap as a `sourceUrl` fetch, so the two paths agree.
    static let maxBytes = SupportFileURLFetcher.maxBytes
    static let maxBytesText = SupportFileURLFetcher.maxBytesText
    /// How long an upload stays usable after `begin`.
    static let lifetime: TimeInterval = 30 * 60
    /// How many live uploads one grant may hold at once, so a loop cannot
    /// fill the database.
    static let maxOpenPerOwner = 10

    /// The grant an upload belongs to.
    struct Owner: Sendable, Equatable {
        let subject: String
        let clientID: String?
    }

    /// What `begin` returns: the id the URL and the tools take, and when it
    /// expires.
    struct Ticket: Sendable {
        let id: UUID
        let expiresAt: Date
    }

    /// What the PUT stored.
    struct Received: Sendable, Equatable {
        let id: UUID
        let sizeBytes: Int
        let sha256: String
    }

    /// A stored upload, ready for a write tool.
    struct Staged: Sendable {
        let id: UUID
        let bytes: Data

        /// The bytes as text. The PUT already refused non-UTF-8 bytes.
        func text() throws(MCPUploadError) -> String {
            guard let text = String(data: bytes, encoding: .utf8) else { throw .notUTF8 }
            return text
        }
    }

    // MARK: - Begin

    /// Records an upload for `owner` in `courseID`. `token` is the secret the
    /// PUT must present; only its hash is stored.
    static func begin(
        owner: Owner, courseID: UUID, token: String, on db: any Database, now: Date = Date()
    ) async throws -> Ticket {
        try await purgeExpired(on: db, now: now)
        // A nil client compares as IS NULL, so a service token's uploads count too.
        let open = try await MCPUpload.query(on: db)
            .filter(\.$subject == owner.subject)
            .filter(\.$clientID == owner.clientID)
            .count()
        guard open < maxOpenPerOwner else { throw MCPUploadError.tooManyOpen(limit: maxOpenPerOwner) }

        let row = MCPUpload(
            tokenHash: sha256HexDigest(token), subject: owner.subject, clientID: owner.clientID,
            courseID: courseID, expiresAt: now.addingTimeInterval(lifetime))
        try await row.save(on: db)
        return Ticket(id: try row.requireID(), expiresAt: row.expiresAt)
    }

    // MARK: - Receive (the PUT)

    /// Stores `bytes` for upload `id`, when `token` is its secret. A body that
    /// breaks the rules is refused before anything is claimed, so the agent
    /// can PUT a good file to the same URL.
    static func receive(
        id: UUID, token: String, bytes: Data, on db: any Database, now: Date = Date()
    ) async throws -> Received {
        let tokenHash = sha256HexDigest(token)
        guard
            let row = try await MCPUpload.query(on: db)
                .filter(\.$id == id).filter(\.$tokenHash == tokenHash)
                .field(\.$id).field(\.$expiresAt).field(\.$uploadedAt)
                .first()
        else { throw MCPUploadError.unknownUpload }
        guard row.expiresAt > now else { throw MCPUploadError.expired }
        guard row.uploadedAt == nil else { throw MCPUploadError.alreadyUploaded }
        try validate(bytes)

        // Claim the URL with one conditional UPDATE, so two concurrent PUTs
        // cannot both store (the SingleUseRecord pattern). `load` refuses the
        // row until the bytes below are written.
        guard try await claim(id: id, tokenHash: tokenHash, on: db, now: now) else {
            throw MCPUploadError.alreadyUploaded
        }
        let digest = sha256HexDigest(bytes)
        try await MCPUpload.query(on: db)
            .filter(\.$id == id)
            .set(\.$bytes, to: bytes)
            .set(\.$sha256, to: digest)
            .update()
        return Received(id: id, sizeBytes: bytes.count, sha256: digest)
    }

    /// Sets `uploaded_at` on a live, unclaimed row, and returns true only when
    /// this call set it.
    private static func claim(id: UUID, tokenHash: String, on db: any Database, now: Date) async throws -> Bool {
        guard let sql = db as? (any SQLDatabase) else { return true }
        let rows = try await sql.raw(
            """
            UPDATE mcp_uploads SET uploaded_at = \(bind: now) \
            WHERE id = \(bind: id) AND token_hash = \(bind: tokenHash) \
            AND uploaded_at IS NULL AND expires_at > \(bind: now) RETURNING id
            """
        ).all()
        return !rows.isEmpty
    }

    /// The size and text rules a PUT must meet.
    static func validate(_ bytes: Data) throws(MCPUploadError) {
        guard bytes.count <= maxBytes else { throw .tooLarge(maxBytes: maxBytes) }
        guard !bytes.isEmpty else { throw .empty }
        guard String(data: bytes, encoding: .utf8) != nil else { throw .notUTF8 }
    }

    // MARK: - Use (a write tool)

    /// The stored upload `rawID`, when it belongs to `owner` and `courseID`, has
    /// been uploaded and has not expired. It is not consumed: call `consume`
    /// after the write succeeds.
    static func load(
        _ rawID: String, owner: Owner, courseID: UUID, on db: any Database, now: Date = Date()
    ) async throws -> Staged {
        let trimmed = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = UUID(uuidString: trimmed) else { throw MCPUploadError.malformedID(rawID) }
        guard let row = try await MCPUpload.find(id, on: db),
            row.subject == owner.subject, row.clientID == owner.clientID
        else { throw MCPUploadError.unknownUpload }
        guard row.expiresAt > now else { throw MCPUploadError.expired }
        guard row.courseID == courseID else { throw MCPUploadError.wrongCourse }
        guard row.uploadedAt != nil, let bytes = row.bytes else { throw MCPUploadError.notUploadedYet }
        return Staged(id: id, bytes: bytes)
    }

    /// Deletes a used upload, so it cannot be used again.
    static func consume(_ id: UUID, on db: any Database) async throws {
        try await MCPUpload.query(on: db).filter(\.$id == id).delete()
    }

    // MARK: - Cleanup

    /// Deletes every upload past its expiry.
    static func purgeExpired(on db: any Database, now: Date = Date()) async throws {
        try await MCPUpload.query(on: db).filter(\.$expiresAt <= now).delete()
    }

}
