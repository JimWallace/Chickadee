// APIServer/Services/CourseContentService.swift
//
// The validation and the writes for course content items, shared by the web
// routes (`CourseAdminRoutes+ContentItems.swift`) and the MCP tools
// (`CourseContentItemTools.swift`) (#2769). Each surface wrote them once, and
// they drifted: the web stored an unknown kind as a link, while MCP refused it
// (#2337).
//
// Authorization stays at each surface, because each one resolves the course
// in its own way (the active course on the web, a course code in MCP). So does
// the section lookup: the web ignores a section in another course, and MCP
// refuses it. A surface authorizes, builds a draft or an edit, and calls the
// service. It maps a `CourseContentError` to its own error type.

import Core
import Fluent
import Foundation
import Vapor

/// One `{label, url}` link as a surface supplies it. MCP decodes it from the
/// tool arguments; the web builds it from the parallel form arrays.
struct ContentLinkInput: Decodable, Sendable {
    let label: String?
    let url: String
}

/// A validated new content item. The initializer holds every rule for the
/// fields, so a draft that exists is valid.
struct ContentItemDraft: Sendable {
    let title: String
    let kind: ContentItemKind
    let itemDescription: String?
    let links: [ContentLink]
    let updatedLabel: String?
    let isPublished: Bool

    /// A nil `kind` is a link. A kind that is not a `ContentItemKind` is
    /// refused.
    init(
        title: String, kind: String?, links: [ContentLinkInput], description: String?,
        updatedLabel: String?, isPublished: Bool
    ) throws(CourseContentError) {
        self.title = try CourseContentService.validatedTitle(title)
        self.kind = try CourseContentService.parseKind(kind) ?? .link
        self.links = try CourseContentService.validatedLinks(links)
        self.itemDescription = CourseContentService.normalizedText(description)
        self.updatedLabel = CourseContentService.normalizedText(updatedLabel)
        self.isPublished = isPublished
    }
}

/// A change to an existing content item. A nil field is left unchanged.
struct ContentItemEdit: Sendable {
    var title: String?
    var kind: String?
    /// When present (even empty), replaces the item's links.
    var links: [ContentLinkInput]?
    /// "" clears.
    var description: String?
    /// "" clears.
    var updatedLabel: String?
    var isPublished: Bool?

    /// True when the edit changes no field.
    var isEmpty: Bool {
        title == nil && kind == nil && links == nil && description == nil && updatedLabel == nil
            && isPublished == nil
    }
}

enum CourseContentService {

    // MARK: - Field rules

    /// The trimmed title. An empty title is refused.
    static func validatedTitle(_ raw: String) throws(CourseContentError) -> String {
        let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw .emptyTitle }
        return title
    }

    /// The kind for `raw`: nil in, nil out. A value that is not a
    /// `ContentItemKind` is refused, and is never stored as a link.
    static func parseKind(_ raw: String?) throws(CourseContentError) -> ContentItemKind? {
        guard let raw else { return nil }
        guard let kind = ContentItemKind(rawValue: raw) else { throw .unknownKind(raw) }
        return kind
    }

    /// Validates and maps input links to `[ContentLink]`. A row with no label
    /// and no URL is dropped, and a blank label becomes the URL. Only http(s)
    /// and site-relative links are allowed: the values render as `href`s, so
    /// `javascript:` and `data:` are refused.
    static func validatedLinks(_ inputs: [ContentLinkInput]) throws(CourseContentError) -> [ContentLink] {
        var links: [ContentLink] = []
        for input in inputs {
            let label = (input.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url = input.url.trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty, url.isEmpty { continue }
            guard !url.isEmpty else { throw .linkMissingURL(label: label) }
            guard isSafeLinkURL(url) else { throw .unsafeLinkURL(url) }
            links.append(ContentLink(label: label.isEmpty ? url : label, url: url))
        }
        return links
    }

    /// Trims, and maps an empty string to nil, for the optional text fields.
    static func normalizedText(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    private static func isSafeLinkURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || url.hasPrefix("/")
    }

    // MARK: - Writes

    /// Saves a new item at the end of its section's lane. The caller has
    /// authorized the write to `courseID` and resolved `sectionID` in it.
    static func create(
        _ draft: ContentItemDraft, courseID: UUID, sectionID: UUID?, on db: any Database
    ) async throws -> APICourseContentItem {
        let sortOrder = try await nextSectionItemSortOrder(
            courseID: courseID, sectionID: sectionID, db: db)
        let item = APICourseContentItem(
            courseID: courseID,
            sectionID: sectionID,
            sortOrder: sortOrder,
            title: draft.title,
            kind: draft.kind,
            itemDescription: draft.itemDescription,
            links: draft.links,
            updatedLabel: draft.updatedLabel,
            isPublished: draft.isPublished)
        try await item.save(on: db)
        return item
    }

    /// Validates every field of `edit` and then applies it to `item`, so a
    /// refused edit changes nothing. Does not save.
    static func apply(_ edit: ContentItemEdit, to item: APICourseContentItem) throws(CourseContentError) {
        let title = try edit.title.map(validatedTitle)
        let kind = try parseKind(edit.kind)
        let links = try edit.links.map(validatedLinks)
        if let title { item.title = title }
        if let kind { item.kind = kind }
        if let links { item.links = links }
        if let description = edit.description { item.itemDescription = normalizedText(description) }
        if let updatedLabel = edit.updatedLabel { item.updatedLabel = normalizedText(updatedLabel) }
        if let isPublished = edit.isPublished { item.isPublished = isPublished }
    }

    /// Applies `edit` and saves. When `newSectionID` is given (an outer nil
    /// means "do not move", an inner nil means "ungroup") and differs from the
    /// item's section, the item moves to the end of that lane. Throws a
    /// `CourseContentError` before any write when a field is refused.
    static func update(
        _ item: APICourseContentItem, with edit: ContentItemEdit, movingTo newSectionID: UUID?? = nil,
        on db: any Database
    ) async throws {
        try apply(edit, to: item)
        if let newSectionID, newSectionID != item.sectionID {
            item.sectionID = newSectionID
            item.sortOrder = try await nextSectionItemSortOrder(
                courseID: item.courseID, sectionID: newSectionID, db: db)
        }
        try await item.save(on: db)
    }

    /// Puts the item at the end of `sectionID`'s lane (nil = ungrouped) and
    /// saves, even when it is already in that section. The drag-and-drop
    /// client follows with a reorder that places it exactly.
    static func place(
        _ item: APICourseContentItem, inSection sectionID: UUID?, on db: any Database
    ) async throws {
        item.sectionID = sectionID
        item.sortOrder = try await nextSectionItemSortOrder(
            courseID: item.courseID, sectionID: sectionID, db: db)
        try await item.save(on: db)
    }

    /// Deletes the item and its hosted attachment files.
    static func delete(
        _ item: APICourseContentItem, application: Application, on db: any Database
    ) async throws {
        if let itemID = item.id {
            ContentAttachmentStore.removeDirectory(application, itemID: itemID)
        }
        try await item.delete(on: db)
    }
}
