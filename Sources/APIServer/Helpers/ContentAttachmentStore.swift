// APIServer/Helpers/ContentAttachmentStore.swift
//
// Validates and stores hosted file attachments for course content items — the
// shared core behind the web upload (multipart File bytes) and the MCP fetch
// (SSRF-guarded URL → Data). Files land at
// `contentFilesDirectory/<itemID>/<attachmentID>` under a server-generated
// name, so a hostile original filename can never escape the directory; the
// untrusted name is validated (bare filename, allowed extension, size cap) and
// kept only as display / download metadata.

import Core
import Foundation
import Vapor

enum ContentAttachmentStore {
    /// Extensions instructors may host: reference material — documents,
    /// notebooks, images, small data. No executables or code archives.
    static let allowedExtensions: Set<String> = [
        "pdf", "ipynb", "png", "jpg", "jpeg", "gif", "svg", "webp",
        "txt", "md", "csv", "tsv", "json", "py", "docx", "pptx", "xlsx",
    ]
    /// Per-file cap. The upload route's body limit is set higher so a few files
    /// plus form fields fit in one multipart request.
    static let maxFileBytes = 25 * 1024 * 1024

    enum StoreError: Error, Equatable {
        case unsafeName(String)
        case disallowedType(String)
        case tooLarge(name: String)

        /// Human-readable reason for a web `WebAssignmentError.invalidParameter`
        /// or an MCP `invalidArguments` detail.
        var reason: String {
            switch self {
            case .unsafeName(let name):
                return "File name \"\(name)\" is not a valid bare filename."
            case .disallowedType(let ext):
                let list = ContentAttachmentStore.allowedExtensions.sorted().joined(separator: ", ")
                return "File type \".\(ext)\" is not allowed. Allowed: \(list)."
            case .tooLarge(let name):
                return "File \"\(name)\" exceeds the \(maxFileBytes / (1024 * 1024)) MB limit."
            }
        }
    }

    /// Absolute directory holding one item's attachment files.
    static func directory(_ app: Application, itemID: UUID) -> String {
        app.contentFilesDirectory + itemID.uuidString + "/"
    }

    /// Absolute on-disk path of one attachment file.
    static func path(_ app: Application, itemID: UUID, attachmentID: UUID) -> String {
        directory(app, itemID: itemID) + attachmentID.uuidString
    }

    /// Validates the name / extension / size WITHOUT writing, returning the
    /// sanitized bare filename. Lets a caller pre-check every file in a batch
    /// before writing any, so a partial batch never leaves files on disk.
    @discardableResult
    static func validate(bytes: Data, originalName rawName: String) throws -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let safeName = FilenameSafety.bareFilename(trimmed) else {
            throw StoreError.unsafeName(trimmed)
        }
        let ext = (safeName as NSString).pathExtension.lowercased()
        guard allowedExtensions.contains(ext) else { throw StoreError.disallowedType(ext) }
        guard bytes.count <= maxFileBytes else { throw StoreError.tooLarge(name: safeName) }
        return safeName
    }

    /// Validates then writes the bytes under a freshly generated attachment id,
    /// returning the metadata to append to the item.
    static func store(
        bytes: Data, originalName rawName: String, label: String?, sortOrder: Int,
        itemID: UUID, on req: Request
    ) async throws -> ContentAttachment {
        let safeName = try validate(bytes: bytes, originalName: rawName)

        let attachmentID = UUID()
        let dir = directory(req.application, itemID: itemID)
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try await req.fileio.writeFile(.init(data: bytes), at: dir + attachmentID.uuidString)

        let cleanLabel = label?.trimmingCharacters(in: .whitespacesAndNewlines)
        return ContentAttachment(
            id: attachmentID, originalName: safeName, sizeBytes: bytes.count,
            sortOrder: sortOrder, label: (cleanLabel?.isEmpty == false) ? cleanLabel : nil)
    }

    /// Best-effort removal of one attachment's file (a missing file is fine).
    static func removeFile(_ app: Application, itemID: UUID, attachmentID: UUID) {
        try? FileManager.default.removeItem(
            atPath: path(app, itemID: itemID, attachmentID: attachmentID))
    }

    /// Best-effort removal of an item's entire attachment directory (on delete).
    static func removeDirectory(_ app: Application, itemID: UUID) {
        try? FileManager.default.removeItem(atPath: directory(app, itemID: itemID))
    }
}
