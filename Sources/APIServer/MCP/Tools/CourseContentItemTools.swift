// APIServer/MCP/Tools/CourseContentItemTools.swift
//
// Tools for *course content items* — ungraded reference material (links,
// notebooks, slides, outlines, headings) shown to students inside a course
// section alongside graded assignments. A content item (`APICourseContentItem`)
// has a title, a kind, an ordered list of labelled links, an optional
// description and "updated" label, a published flag, and belongs to at most one
// course section via its nullable `sectionID`.
//
// These mirror the web instructor handlers (`CourseAdminRoutes+ContentItems.swift`)
// and sit beside the course-section tools (`CourseSectionTools.swift`). Content
// authoring is TA+ (matching script / notebook editing), so the write tools use
// `resolveCourseIDForWrite(atLeast: .ta)`. Content items own no test setup, so
// editing them never closes an assignment, re-validates, or re-grades.

import Core
import Fluent
import Foundation

// MARK: - Shared DTO + helpers

/// The over-the-wire shape of one content item, shared by every tool's output.
struct ContentItemDTO: Encodable, Sendable {
    struct Link: Encodable, Sendable {
        let label: String
        let url: String
    }
    /// One hosted file attachment (metadata + the gated download path).
    struct Attachment: Encodable, Sendable {
        let attachmentID: String
        let originalName: String
        let sizeBytes: Int
        let label: String?
        /// Enrollment-gated download path: /content-files/<itemID>/<attachmentID>.
        let downloadPath: String
    }
    let contentItemID: String
    /// The owning section's id, or "" when ungrouped.
    let courseSectionID: String
    let title: String
    let kind: String
    let description: String?
    let links: [Link]
    let attachments: [Attachment]
    let updatedLabel: String?
    let isPublished: Bool
    let sortOrder: Int
}

/// One `{label, url}` link as accepted on input.
struct ContentLinkInput: Decodable, Sendable {
    let label: String?
    let url: String
}

/// One attachment to fetch by URL and host, as accepted on input.
struct ContentAttachmentInput: Decodable, Sendable {
    let label: String?
    let sourceUrl: String
}

func contentItemDTO(from item: APICourseContentItem) -> ContentItemDTO {
    let itemID = item.id?.uuidString ?? ""
    return ContentItemDTO(
        contentItemID: itemID,
        courseSectionID: item.sectionID?.uuidString ?? "",
        title: item.title,
        kind: item.kind.rawValue,
        description: item.itemDescription,
        links: item.links.map { ContentItemDTO.Link(label: $0.label, url: $0.url) },
        attachments: item.attachments.map { attachment in
            ContentItemDTO.Attachment(
                attachmentID: attachment.id.uuidString,
                originalName: attachment.originalName,
                sizeBytes: attachment.sizeBytes,
                label: attachment.label,
                downloadPath: "/content-files/\(itemID)/\(attachment.id.uuidString)")
        },
        updatedLabel: item.updatedLabel,
        isPublished: item.isPublished,
        sortOrder: item.sortOrder)
}

/// Derives a bare filename from an attachment's source URL (its last path
/// component, percent-decoded); the store then validates the extension + size.
func attachmentFilename(fromURL urlString: String) -> String {
    guard let comps = URLComponents(string: urlString) else { return "attachment" }
    let last = (comps.path as NSString).lastPathComponent
    let decoded = last.removingPercentEncoding ?? last
    return decoded.isEmpty || decoded == "/" ? "attachment" : decoded
}

/// Fetches each attachment's sourceUrl under the SSRF guard and stores it on the
/// item, appending to any existing attachments. Order mirrors author_script's
/// materialize: authz (already done by the caller) → cheap validate → fetch →
/// store. A fetch or validation failure surfaces as an `invalidArguments`
/// detail so the agent learns why.
func fetchAndStoreContentAttachments(
    _ inputs: [ContentAttachmentInput], for item: APICourseContentItem,
    tool: String, context: ToolContext
) async throws {
    guard !inputs.isEmpty, let itemID = item.id else { return }
    var attachments = item.attachments
    var nextOrder = (attachments.map(\.sortOrder).max() ?? 0) + 1
    for input in inputs {
        let bytes: Data
        do {
            bytes = try await SupportFileURLFetcher.fetchData(
                urlString: input.sourceUrl, on: context.request)
        } catch let error as SupportFileFetchError {
            throw MCPToolError.invalidArguments(tool: tool, detail: error.toolDetail)
        }
        do {
            let attachment = try await ContentAttachmentStore.store(
                bytes: bytes, originalName: attachmentFilename(fromURL: input.sourceUrl),
                label: input.label, sortOrder: nextOrder, itemID: itemID, on: context.request)
            attachments.append(attachment)
            nextOrder += 1
        } catch let error as ContentAttachmentStore.StoreError {
            throw MCPToolError.invalidArguments(tool: tool, detail: error.reason)
        }
    }
    item.attachments = attachments
    try await item.save(on: context.db)
}

/// http(s) or site-relative only — the URLs render as `href`s, so `javascript:`
/// / `data:` are refused.
private func isSafeContentLinkURL(_ url: String) -> Bool {
    let lower = url.lowercased()
    return lower.hasPrefix("http://") || lower.hasPrefix("https://") || url.hasPrefix("/")
}

/// Validates + maps input links to `[ContentLink]`, dropping fully-blank rows,
/// defaulting a blank label to the URL, and rejecting unsafe schemes.
func contentLinksFromInput(_ links: [ContentLinkInput], tool: String) throws -> [ContentLink] {
    var out: [ContentLink] = []
    for link in links {
        let label = (link.label ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let url = link.url.trimmingCharacters(in: .whitespacesAndNewlines)
        if label.isEmpty, url.isEmpty { continue }
        guard !url.isEmpty else {
            throw MCPToolError.invalidArguments(
                tool: tool, detail: "A link labelled \"\(label)\" is missing a url.")
        }
        guard isSafeContentLinkURL(url) else {
            throw MCPToolError.invalidArguments(
                tool: tool,
                detail: "Link url \"\(url)\" must be an http(s) or site-relative (/…) URL.")
        }
        out.append(ContentLink(label: label.isEmpty ? url : label, url: url))
    }
    return out
}

/// Resolves a content item by id and authorizes the acting account for a write
/// to its course (TA+, archived-course block). Shared by update / delete.
func resolveContentItemForWrite(
    contentItemID raw: String, tool: String, context: ToolContext, atLeast minimum: CourseRole = .ta
) async throws -> APICourseContentItem {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let uuid = UUID(uuidString: trimmed) else {
        throw MCPToolError.invalidArguments(
            tool: tool, detail: "contentItemID \"\(trimmed)\" is not a valid id.")
    }
    guard let item = try await APICourseContentItem.find(uuid, on: context.db) else {
        throw MCPToolError.invalidArguments(tool: tool, detail: "No content item with id \"\(trimmed)\".")
    }
    try await context.authorizeCourseWriteAccess(item.courseID, tool: tool, atLeast: minimum)
    return item
}

/// Resolves a target section id for a content item within `courseID`: nil for
/// empty / "none", a validated UUID otherwise. A non-empty id that doesn't
/// resolve to a section in this course is rejected (typos surface as errors).
func resolveContentItemSectionID(
    _ raw: String?, courseID: UUID, tool: String, context: ToolContext
) async throws -> UUID? {
    let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let trimmed, !trimmed.isEmpty, trimmed.lowercased() != "none" else { return nil }
    guard let uuid = UUID(uuidString: trimmed) else {
        throw MCPToolError.invalidArguments(
            tool: tool, detail: "courseSectionID \"\(trimmed)\" is not a valid id.")
    }
    guard let section = try await APICourseSection.find(uuid, on: context.db),
        section.courseID == courseID
    else {
        throw MCPToolError.invalidArguments(
            tool: tool, detail: "No course section with id \"\(trimmed)\" in this content item's course.")
    }
    return uuid
}

/// Next sort order in the content-item lane of `(course, section)`.
func nextContentItemLaneSortOrder(
    courseID: UUID, sectionID: UUID?, db: any Database
) async throws -> Int {
    let query = APICourseContentItem.query(on: db).filter(\.$courseID == courseID)
    if let sectionID {
        query.filter(\.$sectionID == sectionID)
    } else {
        query.filter(\.$sectionID == nil)
    }
    return (try await query.max(\.$sortOrder) ?? 0) + 1
}

/// Reusable JSON-schema fragment for the `links` array.
private let contentLinksSchema: JSONValue = .object([
    "type": .string("array"),
    "items": .object([
        "type": .string("object"),
        "properties": .object([
            "label": .object([
                "type": .string("string"),
                "description": .string("Short label, e.g. \"PDF\" or \"Jupyter Notebook\"."),
            ]),
            "url": .object([
                "type": .string("string"),
                "description": .string("Link target: an http(s) URL or a site-relative /… path."),
            ]),
        ]),
        "required": .array([.string("url")]),
    ]),
    "description": .string(
        "Ordered labelled links for this material (one item can carry several formats)."),
])

/// Reusable JSON-schema fragment for a single content item in outputs.
private let contentItemObjectSchema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
        "contentItemID": MCPSchema.string,
        "courseSectionID": MCPSchema.string,
        "title": MCPSchema.string,
        "kind": MCPSchema.string,
        "description": MCPSchema.string,
        "links": .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "label": MCPSchema.string,
                    "url": MCPSchema.string,
                ]),
                "required": .array([.string("label"), .string("url")]),
            ]),
        ]),
        "attachments": .object([
            "type": .string("array"),
            "items": .object([
                "type": .string("object"),
                "properties": .object([
                    "attachmentID": MCPSchema.string,
                    "originalName": MCPSchema.string,
                    "sizeBytes": MCPSchema.integer,
                    "label": MCPSchema.string,
                    "downloadPath": MCPSchema.string,
                ]),
                "required": .array([
                    .string("attachmentID"), .string("originalName"), .string("sizeBytes"),
                    .string("downloadPath"),
                ]),
            ]),
        ]),
        "updatedLabel": MCPSchema.string,
        "isPublished": MCPSchema.boolean,
        "sortOrder": MCPSchema.integer,
    ]),
    "required": .array([
        .string("contentItemID"), .string("courseSectionID"), .string("title"),
        .string("kind"), .string("links"), .string("attachments"), .string("isPublished"),
        .string("sortOrder"),
    ]),
])

/// Reusable JSON-schema fragment for the `attachments` input array (files the
/// server fetches by URL and hosts).
private let attachmentsInputSchema: JSONValue = .object([
    "type": .string("array"),
    "items": .object([
        "type": .string("object"),
        "properties": .object([
            "label": .object([
                "type": .string("string"),
                "description": .string("Optional label; falls back to the file name."),
            ]),
            "sourceUrl": .object([
                "type": .string("string"),
                "description": .string(
                    "https URL the server fetches under an SSRF guard (https only, no "
                        + "private/loopback/metadata hosts, no redirects, 25 MB cap). The URL's last "
                        + "path segment becomes the stored filename; its extension must be an allowed "
                        + "type (pdf, ipynb, png/jpg/gif/svg/webp, txt/md/csv/tsv/json/py, "
                        + "docx/pptx/xlsx)."),
            ]),
        ]),
        "required": .array([.string("sourceUrl")]),
    ]),
    "description": .string(
        "Files to host on this item — each fetched from an https URL and served to enrolled "
            + "students through the gated /content-files route. Appended to any existing attachments."),
])

private let kindEnumSchema: JSONValue = .object([
    "type": .string("string"),
    "enum": .array(ContentItemKind.allCases.map { .string($0.rawValue) }),
    "description": .string(
        "Icon / label hint: link, notebook, document, slides, outline, or heading."),
])

// MARK: - list_content_items

struct ListContentItemsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
    }

    struct Output: Encodable, Sendable {
        let courseCode: String
        let contentItems: [ContentItemDTO]
    }

    static let name = "list_content_items"
    static let description =
        "List a course's ungraded content items (reference material like lecture slides, notebooks, "
        + "or links shown inside a course section), by course code, in display order. Returns each "
        + "item's id, its course section (courseSectionID, \"\" when ungrouped), title, kind, links, "
        + "description, updated label, published flag, and sort order. These are ungraded materials — "
        + "not assignments (use list_assignments) and not test-suite sections (use get_suite)."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode
        ]),
        "required": .array([.string("courseCode")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "contentItems": .object([
                "type": .string("array"),
                "items": contentItemObjectSchema,
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("contentItems")]),
    ])
    static let requiredScopes: Set<ContentScope> = [.read]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let courseID = try await resolveCourseID(code: input.courseCode, tool: Self.name, context: context)
        let items = try await APICourseContentItem.query(on: context.db)
            .filter(\.$courseID == courseID)
            .sort(\.$sortOrder)
            .all()
        return Output(courseCode: input.courseCode, contentItems: items.map(contentItemDTO(from:)))
    }
}

// MARK: - create_content_item

struct CreateContentItemTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        let title: String
        let kind: String?
        let links: [ContentLinkInput]?
        /// Files to fetch by URL and host on the item.
        let attachments: [ContentAttachmentInput]?
        let description: String?
        let updatedLabel: String?
        /// Course-section id (from list_course_sections); "" / omitted = ungrouped.
        let courseSectionID: String?
        /// Defaults to true (visible to students).
        let isPublished: Bool?

        // Explicit init so the memberwise form keeps working with `attachments`
        // defaulted (the synthesized Decodable init handles the wire decode).
        init(
            courseCode: String, title: String, kind: String? = nil,
            links: [ContentLinkInput]? = nil, attachments: [ContentAttachmentInput]? = nil,
            description: String? = nil, updatedLabel: String? = nil, courseSectionID: String? = nil,
            isPublished: Bool? = nil
        ) {
            self.courseCode = courseCode
            self.title = title
            self.kind = kind
            self.links = links
            self.attachments = attachments
            self.description = description
            self.updatedLabel = updatedLabel
            self.courseSectionID = courseSectionID
            self.isPublished = isPublished
        }
    }

    typealias Output = ContentItemDTO

    static let name = "create_content_item"
    static let description =
        "Create an ungraded content item (reference material — a link, notebook, slides, document, "
        + "outline, or heading) in a course, by course code. Provide a title and optionally a kind, "
        + "links (each {label, url}; http(s) or site-relative only), description, updatedLabel, "
        + "courseSectionID (from list_course_sections; omit to leave ungrouped), and isPublished "
        + "(default true — set false to hide it from students). attachments hosts files fetched from "
        + "https URLs (served to enrolled students through the gated /content-files route). Appended "
        + "to the end of its section's content lane. This is ungraded material: it creates no test "
        + "setup and triggers no grading."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "title": .object([
                "type": .string("string"),
                "description": .string("Display title (non-empty), e.g. \"Lecture 1\"."),
            ]),
            "kind": kindEnumSchema,
            "links": contentLinksSchema,
            "attachments": attachmentsInputSchema,
            "description": .object([
                "type": .string("string"),
                "description": .string("Optional descriptive blurb shown under the title."),
            ]),
            "updatedLabel": .object([
                "type": .string("string"),
                "description": .string("Optional \"Updated\" label shown on the row, e.g. \"2026-05-11\"."),
            ]),
            "courseSectionID": .object([
                "type": .string("string"),
                "description": .string("Target course-section id, or \"\" to leave ungrouped."),
            ]),
            "isPublished": .object([
                "type": .string("boolean"),
                "description": .string("Visible to students. Default true; false hides it as a draft."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("title")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = contentItemObjectSchema
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: false)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let title = input.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw MCPToolError.invalidArguments(tool: Self.name, detail: "title must not be empty.")
        }
        let courseID = try await resolveCourseIDForWrite(
            code: input.courseCode, tool: Self.name, context: context, atLeast: .ta)
        let kind = ContentItemKind(rawValue: input.kind ?? "") ?? .link
        let links = try contentLinksFromInput(input.links ?? [], tool: Self.name)
        let sectionID = try await resolveContentItemSectionID(
            input.courseSectionID, courseID: courseID, tool: Self.name, context: context)
        let sortOrder = try await nextContentItemLaneSortOrder(
            courseID: courseID, sectionID: sectionID, db: context.db)

        let item = APICourseContentItem(
            courseID: courseID,
            sectionID: sectionID,
            sortOrder: sortOrder,
            title: title,
            kind: kind,
            itemDescription: normalizedContentField(input.description),
            links: links,
            updatedLabel: normalizedContentField(input.updatedLabel),
            isPublished: input.isPublished ?? true)
        try await item.save(on: context.db)
        try await fetchAndStoreContentAttachments(
            input.attachments ?? [], for: item, tool: Self.name, context: context)
        return contentItemDTO(from: item)
    }
}

// MARK: - update_content_item

struct UpdateContentItemTool: ContentTool {
    struct Input: Decodable, Sendable {
        let contentItemID: String
        let title: String?
        let kind: String?
        /// When present (even empty), replaces the item's links entirely.
        let links: [ContentLinkInput]?
        /// Files to fetch by URL and APPEND to the item's attachments (never
        /// removes existing ones).
        let attachments: [ContentAttachmentInput]?
        /// "" clears; omit to leave unchanged.
        let description: String?
        /// "" clears; omit to leave unchanged.
        let updatedLabel: String?
        let isPublished: Bool?
        /// "" / "none" ungroups; omit to leave unchanged.
        let courseSectionID: String?

        // Explicit init so the memberwise form keeps working with `attachments`
        // defaulted (the synthesized Decodable init handles the wire decode).
        init(
            contentItemID: String, title: String? = nil, kind: String? = nil,
            links: [ContentLinkInput]? = nil, attachments: [ContentAttachmentInput]? = nil,
            description: String? = nil, updatedLabel: String? = nil, isPublished: Bool? = nil,
            courseSectionID: String? = nil
        ) {
            self.contentItemID = contentItemID
            self.title = title
            self.kind = kind
            self.links = links
            self.attachments = attachments
            self.description = description
            self.updatedLabel = updatedLabel
            self.isPublished = isPublished
            self.courseSectionID = courseSectionID
        }
    }

    typealias Output = ContentItemDTO

    static let name = "update_content_item"
    static let description =
        "Update an ungraded content item by id (from list_content_items). Any provided field is "
        + "changed; omitted fields are left unchanged. title/kind replace; links (when given, even "
        + "empty) replaces the whole link list; description/updatedLabel accept \"\" to clear; "
        + "isPublished toggles student visibility; courseSectionID moves it (\"\"/\"none\" ungroups); "
        + "attachments fetches more files by URL and appends them (to remove a hosted file, use the "
        + "web editor). Ungraded material — no test setup, no re-validation, no re-grade."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "contentItemID": .object([
                "type": .string("string"),
                "description": .string("Content-item id (from list_content_items)."),
            ]),
            "title": .object([
                "type": .string("string"),
                "description": .string("New title (non-empty); omit to leave unchanged."),
            ]),
            "kind": kindEnumSchema,
            "links": contentLinksSchema,
            "attachments": attachmentsInputSchema,
            "description": .object([
                "type": .string("string"),
                "description": .string("New description; \"\" clears; omit to leave unchanged."),
            ]),
            "updatedLabel": .object([
                "type": .string("string"),
                "description": .string("New updated label; \"\" clears; omit to leave unchanged."),
            ]),
            "isPublished": .object([
                "type": .string("boolean"),
                "description": .string("Student visibility; omit to leave unchanged."),
            ]),
            "courseSectionID": .object([
                "type": .string("string"),
                "description": .string(
                    "Move to this course section; \"\" / \"none\" ungroups; omit to leave unchanged."),
            ]),
        ]),
        "required": .array([.string("contentItemID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = contentItemObjectSchema
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        guard
            input.title != nil || input.kind != nil || input.links != nil
                || input.attachments != nil || input.description != nil || input.updatedLabel != nil
                || input.isPublished != nil || input.courseSectionID != nil
        else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "Provide at least one field to change.")
        }
        let item = try await resolveContentItemForWrite(
            contentItemID: input.contentItemID, tool: Self.name, context: context)

        if let title = input.title {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw MCPToolError.invalidArguments(tool: Self.name, detail: "title must not be empty.")
            }
            item.title = trimmed
        }
        if let kind = input.kind {
            guard let parsed = ContentItemKind(rawValue: kind) else {
                throw MCPToolError.invalidArguments(
                    tool: Self.name, detail: "kind \"\(kind)\" is not a recognised content-item kind.")
            }
            item.kind = parsed
        }
        if let links = input.links {
            item.links = try contentLinksFromInput(links, tool: Self.name)
        }
        if let description = input.description {
            item.itemDescription = normalizedContentField(description)
        }
        if let updatedLabel = input.updatedLabel {
            item.updatedLabel = normalizedContentField(updatedLabel)
        }
        if let isPublished = input.isPublished {
            item.isPublished = isPublished
        }
        if let rawSection = input.courseSectionID {
            let newSectionID = try await resolveContentItemSectionID(
                rawSection, courseID: item.courseID, tool: Self.name, context: context)
            if newSectionID != item.sectionID {
                item.sectionID = newSectionID
                item.sortOrder = try await nextContentItemLaneSortOrder(
                    courseID: item.courseID, sectionID: newSectionID, db: context.db)
            }
        }
        try await item.save(on: context.db)
        try await fetchAndStoreContentAttachments(
            input.attachments ?? [], for: item, tool: Self.name, context: context)
        return contentItemDTO(from: item)
    }
}

// MARK: - delete_content_item

struct DeleteContentItemTool: ContentTool {
    struct Input: Decodable, Sendable {
        let contentItemID: String
    }

    struct Output: Encodable, Sendable {
        let contentItemID: String
        /// false when no item with that id existed (idempotent no-op).
        let removed: Bool
    }

    static let name = "delete_content_item"
    static let description =
        "Delete an ungraded content item by id (from list_content_items). Removes only the reference "
        + "material — never an assignment or a section. Idempotent: deleting an id that no longer "
        + "exists reports removed=false."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "contentItemID": .object([
                "type": .string("string"),
                "description": .string("Content-item id (from list_content_items)."),
            ])
        ]),
        "required": .array([.string("contentItemID")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "contentItemID": MCPSchema.string,
            "removed": MCPSchema.boolean,
        ]),
        "required": .array([.string("contentItemID"), .string("removed")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: true, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let raw = input.contentItemID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let uuid = UUID(uuidString: raw) else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "contentItemID \"\(raw)\" is not a valid id.")
        }
        // Unknown id is an idempotent no-op, revealing nothing that distinguishes
        // "doesn't exist" from "in a course you can't see".
        guard let item = try await APICourseContentItem.find(uuid, on: context.db) else {
            return Output(contentItemID: raw, removed: false)
        }
        try await context.authorizeCourseWriteAccess(item.courseID, tool: Self.name, atLeast: .ta)
        if let itemID = item.id {
            ContentAttachmentStore.removeDirectory(context.request.application, itemID: itemID)
        }
        try await item.delete(on: context.db)
        return Output(contentItemID: raw, removed: true)
    }
}

// MARK: - reorder_content_items

struct ReorderContentItemsTool: ContentTool {
    struct Input: Decodable, Sendable {
        let courseCode: String
        /// Content-item ids in the new display order — a permutation of the ids
        /// in a single section's content lane.
        let orderedContentItemIDs: [String]
    }

    struct Output: Encodable, Sendable {
        let courseCode: String
        let contentItems: [ContentItemDTO]
    }

    static let name = "reorder_content_items"
    static let description =
        "Set the display order of content items within one section's content lane, by course code. "
        + "orderedContentItemIDs must all belong to the same course (and normally the same section) — "
        + "they are renumbered 1..n in the given order. Reorders ungraded material only; assignments "
        + "use reorder_assignments and test-suite items use move_suite_item."
    static let inputSchema: JSONValue = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.courseCode,
            "orderedContentItemIDs": .object([
                "type": .string("array"),
                "items": MCPSchema.string,
                "description": .string("Content-item ids in the desired order (same course/lane)."),
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("orderedContentItemIDs")]),
        "additionalProperties": .bool(false),
    ])
    static let outputSchema: JSONValue? = .object([
        "type": .string("object"),
        "properties": .object([
            "courseCode": MCPSchema.string,
            "contentItems": .object([
                "type": .string("array"),
                "items": contentItemObjectSchema,
            ]),
        ]),
        "required": .array([.string("courseCode"), .string("contentItems")]),
    ])
    static let annotations: MCPToolAnnotations? = MCPToolAnnotations(
        readOnlyHint: false, destructiveHint: false, idempotentHint: true)
    static let requiredScopes: Set<ContentScope> = [.write]

    func execute(_ input: Input, _ context: ToolContext) async throws -> Output {
        let courseID = try await resolveCourseIDForWrite(
            code: input.courseCode, tool: Self.name, context: context, atLeast: .ta)
        let uuids = input.orderedContentItemIDs.compactMap {
            UUID(uuidString: $0.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        guard uuids.count == input.orderedContentItemIDs.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "orderedContentItemIDs contains an invalid content-item id.")
        }
        guard Set(uuids).count == uuids.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name, detail: "orderedContentItemIDs contains a duplicate content-item id.")
        }
        guard !uuids.isEmpty else {
            return Output(courseCode: input.courseCode, contentItems: [])
        }
        // Scope to this course so a reorder can't renumber another course's items.
        let items = try await APICourseContentItem.query(on: context.db)
            .filter(\.$courseID == courseID)
            .filter(\.$id ~~ uuids)
            .all()
        guard items.count == uuids.count else {
            throw MCPToolError.invalidArguments(
                tool: Self.name,
                detail: "orderedContentItemIDs must all be content items in course \(input.courseCode).")
        }
        let byID = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (UUID, APICourseContentItem)? in
                guard let id = item.id else { return nil }
                return (id, item)
            })
        var ordered: [ContentItemDTO] = []
        for (index, uuid) in uuids.enumerated() {
            guard let item = byID[uuid] else { continue }
            item.sortOrder = index + 1
            try await item.save(on: context.db)
            ordered.append(contentItemDTO(from: item))
        }
        return Output(courseCode: input.courseCode, contentItems: ordered)
    }
}

// MARK: - Shared

/// Trims and maps an empty string to nil for optional content text fields.
func normalizedContentField(_ raw: String?) -> String? {
    guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
    else { return nil }
    return trimmed
}
