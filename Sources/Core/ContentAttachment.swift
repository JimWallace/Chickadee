// Core/ContentAttachment.swift
//
// A file attached to an ungraded course content item — an instructor-uploaded
// PDF / notebook / image / slide deck, or a file an agent fetched by URL.
// Unlike a `ContentLink` (which points at an external URL), an attachment's
// bytes live on the server at `contentFilesDirectory/<itemID>/<id>` and are
// served only to enrolled students through a gated route. The untrusted
// `originalName` is kept for display and the download filename; the on-disk
// name is the opaque `id`, so a hostile filename can never escape the
// directory.

import Foundation

public struct ContentAttachment: Codable, Sendable, Equatable {
    /// Server-generated; also the on-disk filename under the item's directory.
    public let id: UUID
    /// The uploader's filename, for display and the `Content-Disposition`
    /// download name. Untrusted — validated as a bare filename before storage.
    public let originalName: String
    public let sizeBytes: Int
    /// Order within the item's attachment list (lower = shown first).
    public let sortOrder: Int
    /// Optional instructor label; falls back to `originalName` for display.
    public let label: String?

    public init(
        id: UUID, originalName: String, sizeBytes: Int, sortOrder: Int, label: String? = nil
    ) {
        self.id = id
        self.originalName = originalName
        self.sizeBytes = sizeBytes
        self.sortOrder = sortOrder
        self.label = label
    }

    /// Display name: the instructor label when set, otherwise the file name.
    public var displayName: String {
        if let label, !label.isEmpty { return label }
        return originalName
    }
}
