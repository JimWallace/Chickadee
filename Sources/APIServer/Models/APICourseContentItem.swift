// APIServer/Models/APICourseContentItem.swift
//
// An ungraded content item — reference material (links, notebooks, slides,
// outlines, headings) shown to students inside a course section alongside
// graded assignments. Unlike APIAssignment it owns no test setup, submission,
// or grading lifecycle; it is pure course-structure plus a link payload.
//
// Like assignments, it references its section via a nullable section_id FK
// (SET NULL on delete), so deleting a section drops its content items into the
// "ungrouped" bucket rather than deleting them.

import Core
import Fluent
import Foundation
import Vapor

final class APICourseContentItem: Model, Content, @unchecked Sendable {
    // @unchecked Sendable: all mutations happen within Vapor's request context.
    static let schema = "course_content_items"

    @ID(key: .id)
    var id: UUID?

    /// The course this content item belongs to.
    @Field(key: "course_id")
    var courseID: UUID

    /// The section this item belongs to (nil = ungrouped).
    @OptionalField(key: "section_id")
    var sectionID: UUID?

    /// Order within the content-item lane of its section (lower = shown first).
    @Field(key: "sort_order")
    var sortOrder: Int

    /// Instructor-facing title, e.g. "Lecture 1".
    @Field(key: "title")
    var title: String

    /// Raw `ContentItemKind` — an icon / label hint, not load-bearing.
    @Field(key: "kind")
    var kindRaw: String

    /// Typed accessor for `kindRaw`. Defaults to `.link` for an unrecognised
    /// stored value (the neutral direction).
    var kind: ContentItemKind {
        get { ContentItemKind(rawValue: kindRaw) ?? .link }
        set { kindRaw = newValue.rawValue }
    }

    /// Optional descriptive blurb shown under the title. Named `itemDescription`
    /// to avoid shadowing any `description`; the column is "description".
    @OptionalField(key: "description")
    var itemDescription: String?

    /// JSON-encoded `[ContentLink]`. Stored as a string (rather than a
    /// driver-specific JSON column) to match how manifests are persisted; read
    /// through the `links` accessor rather than this field directly.
    @Field(key: "links_json")
    var linksJSON: String

    /// Decoded links. A malformed/empty stored value yields `[]` rather than
    /// throwing at read time; every write path encodes valid JSON.
    var links: [ContentLink] {
        get {
            guard let data = linksJSON.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([ContentLink].self, from: data)
            else { return [] }
            return decoded
        }
        set { linksJSON = APICourseContentItem.encodeLinks(newValue) }
    }

    /// JSON-encoded `[ContentAttachment]`. Nullable (added after the table
    /// shipped); a NULL or malformed value reads as `[]` through the
    /// `attachments` accessor. Files live at
    /// `contentFilesDirectory/<itemID>/<attachmentID>`.
    @OptionalField(key: "attachments_json")
    var attachmentsJSON: String?

    /// Decoded attachments. A malformed/absent stored value yields `[]` rather
    /// than throwing at read time; every write path encodes valid JSON.
    var attachments: [ContentAttachment] {
        get {
            guard let json = attachmentsJSON, let data = json.data(using: .utf8),
                let decoded = try? JSONDecoder().decode([ContentAttachment].self, from: data)
            else { return [] }
            return decoded
        }
        set { attachmentsJSON = APICourseContentItem.encodeAttachments(newValue) }
    }

    /// Instructor-set "Updated" label shown on the row (free text or an ISO date).
    @OptionalField(key: "updated_label")
    var updatedLabel: String?

    /// When false, the item is hidden from students (staff always see it).
    @Field(key: "is_published")
    var isPublished: Bool

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(
        id: UUID? = nil,
        courseID: UUID,
        sectionID: UUID? = nil,
        sortOrder: Int,
        title: String,
        kind: ContentItemKind = .link,
        itemDescription: String? = nil,
        links: [ContentLink] = [],
        attachments: [ContentAttachment] = [],
        updatedLabel: String? = nil,
        isPublished: Bool = true
    ) {
        self.id = id
        self.courseID = courseID
        self.sectionID = sectionID
        self.sortOrder = sortOrder
        self.title = title
        self.kindRaw = kind.rawValue
        self.itemDescription = itemDescription
        self.linksJSON = APICourseContentItem.encodeLinks(links)
        self.attachmentsJSON = APICourseContentItem.encodeAttachments(attachments)
        self.updatedLabel = updatedLabel
        self.isPublished = isPublished
    }

    /// Serialize links to the stored JSON string, falling back to an empty
    /// array literal if encoding somehow fails (keeps the column non-null).
    static func encodeLinks(_ links: [ContentLink]) -> String {
        guard let data = try? JSONEncoder().encode(links) else { return "[]" }
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }

    /// Serialize attachments to the stored JSON string (same fallback as links).
    static func encodeAttachments(_ attachments: [ContentAttachment]) -> String {
        guard let data = try? JSONEncoder().encode(attachments) else { return "[]" }
        return String(bytes: data, encoding: .utf8) ?? "[]"
    }
}
