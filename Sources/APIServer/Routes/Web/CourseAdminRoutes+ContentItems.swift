// APIServer/Routes/Web/CourseAdminRoutes+ContentItems.swift
//
// Course content-item CRUD — ungraded reference material (links, notebooks,
// slides, outlines) shown inside a course section alongside assignments.
// Mirrors the course-section handlers in `CourseAdminRoutes+Sections.swift`:
// same active-course resolution, `WebAssignmentError` vocabulary, and
// redirect-to-`/instructor` convention. All routes sit under the `/instructor`
// group (staff-gated by `ActiveCourseStaffMiddleware`); each mutating handler
// additionally scopes the write to the resource's own course via
// `requireCourseWriteAccess(atLeast: .ta)` — content authoring is TA+, matching
// script / notebook editing (course-section structure stays instructor-level).

import Core
import Fluent
import Foundation
import Vapor

extension CourseAdminRoutes {

    /// Form payload shared by create + edit. Links arrive as parallel
    /// `linkLabels[]` / `linkURLs[]` arrays so a single item can carry several
    /// format links (e.g. "PDF" + "Jupyter Notebook").
    struct ContentItemFormBody: Content {
        var title: String
        var kind: String?
        var description: String?
        var updatedLabel: String?
        var sectionID: String?
        /// "true" (default) or "false"; a `<select>`, so always submitted.
        var isPublished: String?
        var linkLabels: [String]?
        var linkURLs: [String]?
        /// Uploaded file attachments (one bare `File` or a repeated `File[]`);
        /// empty parts (untouched inputs) are ignored.
        var attachmentFiles: MultipartFileList?
    }

    // MARK: - POST /instructor/content-items

    @Sendable
    func createContentItem(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: "managing content items")
        }
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .ta, db: req.db)

        let body = try req.content.decode(ContentItemFormBody.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "title", reason: "Title must not be empty.")
        }
        let kind = ContentItemKind(rawValue: body.kind ?? "") ?? .link
        let links = try buildContentLinks(labels: body.linkLabels ?? [], urls: body.linkURLs ?? [])
        let sectionID = try await resolveSectionID(body.sectionID, courseID: courseID, db: req.db)
        let sortOrder = try await nextContentItemSortOrder(
            courseID: courseID, sectionID: sectionID, db: req.db)

        let item = APICourseContentItem(
            courseID: courseID,
            sectionID: sectionID,
            sortOrder: sortOrder,
            title: title,
            kind: kind,
            itemDescription: normalizedOptional(body.description),
            links: links,
            updatedLabel: normalizedOptional(body.updatedLabel),
            isPublished: body.isPublished != "false"
        )
        try await item.save(on: req.db)
        try await storeUploadedAttachments(body.attachmentFiles, for: item, req: req)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/content-items/:id/edit

    @Sendable
    func updateContentItem(req: Request) async throws -> Response {
        let item = try await loadContentItemForWrite(req)
        let body = try req.content.decode(ContentItemFormBody.self)
        let title = body.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "title", reason: "Title must not be empty.")
        }
        item.title = title
        item.kind = ContentItemKind(rawValue: body.kind ?? "") ?? .link
        item.links = try buildContentLinks(labels: body.linkLabels ?? [], urls: body.linkURLs ?? [])
        item.itemDescription = normalizedOptional(body.description)
        item.updatedLabel = normalizedOptional(body.updatedLabel)
        item.isPublished = body.isPublished != "false"
        try await item.save(on: req.db)
        try await storeUploadedAttachments(body.attachmentFiles, for: item, req: req)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/content-items/:id/delete

    @Sendable
    func deleteContentItem(req: Request) async throws -> Response {
        let item = try await loadContentItemForWrite(req)
        if let itemID = item.id {
            ContentAttachmentStore.removeDirectory(req.application, itemID: itemID)
        }
        try await item.delete(on: req.db)
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/content-items/:id/attachments/:attachmentID/delete

    /// Removes one hosted attachment from the item (DB entry + file on disk).
    @Sendable
    func removeContentAttachment(req: Request) async throws -> Response {
        let item = try await loadContentItemForWrite(req)
        guard let attachmentRaw = req.parameters.get("attachmentID"),
            let attachmentID = UUID(uuidString: attachmentRaw)
        else {
            throw WebAssignmentError.notFound(resource: "Attachment")
        }
        item.attachments = item.attachments.filter { $0.id != attachmentID }
        try await item.save(on: req.db)
        if let itemID = item.id {
            ContentAttachmentStore.removeFile(req.application, itemID: itemID, attachmentID: attachmentID)
        }
        return req.redirect(to: "/instructor")
    }

    // MARK: - POST /instructor/content-items/reorder

    /// Persists a new order for the content-item lane. `itemIDs` is the lane's
    /// ids in display order; each is renumbered 1..n. AJAX (returns `.ok`).
    @Sendable
    func reorderContentItems(req: Request) async throws -> HTTPStatus {
        struct ReorderBody: Content {
            var itemIDs: [String]
        }
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        guard let courseID = courseState.activeCourseUUID else { return .ok }
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .ta, db: req.db)

        let body = try req.content.decode(ReorderBody.self)
        let uuids = body.itemIDs.compactMap { UUID(uuidString: $0) }
        guard uuids.count == body.itemIDs.count else {
            throw WebAssignmentError.invalidParameter(
                name: "itemIDs", reason: "Invalid content-item ID in reorder payload.")
        }
        guard !uuids.isEmpty else { return .ok }
        // Scope to this course so a reorder can't touch another course's items.
        let items = try await APICourseContentItem.query(on: req.db)
            .filter(\.$courseID == courseID)
            .filter(\.$id ~~ uuids)
            .all()
        guard items.count == uuids.count else {
            throw WebAssignmentError.invalidParameter(
                name: "itemIDs", reason: "Content-item set mismatch in reorder payload.")
        }
        let byID = Dictionary(
            uniqueKeysWithValues: items.compactMap { item -> (UUID, APICourseContentItem)? in
                guard let id = item.id else { return nil }
                return (id, item)
            })
        for (index, uuid) in uuids.enumerated() {
            guard let item = byID[uuid] else { continue }
            item.sortOrder = index + 1
            try await item.save(on: req.db)
        }
        return .ok
    }

    // MARK: - POST /instructor/content-items/:id/section

    /// Moves a content item into another section (or ungroups it). AJAX.
    /// Unlike the assignment move there is no grading-mode sync — content items
    /// have no test setup.
    @Sendable
    func moveContentItemToSection(req: Request) async throws -> HTTPStatus {
        struct MoveBody: Content {
            var sectionID: String?  // UUID string, or "" / absent = ungrouped
        }
        let item = try await loadContentItemForWrite(req)
        let body = try? req.content.decode(MoveBody.self)
        let newSectionID = try await resolveSectionID(
            body?.sectionID, courseID: item.courseID, db: req.db)
        item.sectionID = newSectionID
        // Append to the destination lane so it doesn't collide with an existing
        // sortOrder; the client may follow with a reorder to place it exactly.
        item.sortOrder = try await nextContentItemSortOrder(
            courseID: item.courseID, sectionID: newSectionID, db: req.db)
        try await item.save(on: req.db)
        return .ok
    }

    // MARK: - Helpers

    /// Loads the `:id` content item and authorizes the caller for a write to its
    /// own course (TA+, archived-course block) — scoping the write to the
    /// resource's course rather than the caller's active course.
    private func loadContentItemForWrite(_ req: Request) async throws -> APICourseContentItem {
        guard let idStr = req.parameters.get("id"), let uuid = UUID(uuidString: idStr) else {
            throw WebAssignmentError.notFound(resource: "Content item")
        }
        guard let item = try await APICourseContentItem.find(uuid, on: req.db) else {
            throw WebAssignmentError.notFound(resource: "Content item")
        }
        let caller = try req.auth.require(APIUser.self)
        try await requireCourseWriteAccess(
            caller: caller, courseID: item.courseID, atLeast: .ta, db: req.db)
        return item
    }

    /// Stores any uploaded attachment files on the item. Pre-validates the whole
    /// batch (name / type / size) before writing any, so a bad file never leaves
    /// partial files on disk, then appends to the item's existing attachments and
    /// re-saves. No-op when no (non-empty) files were posted — an untouched file
    /// input posts an empty part.
    private func storeUploadedAttachments(
        _ files: MultipartFileList?, for item: APICourseContentItem, req: Request
    ) async throws {
        guard let itemID = item.id, let files, !files.files.isEmpty else { return }
        let candidates: [(name: String, bytes: Data)] = files.files.compactMap { file in
            let bytes = Data(file.data.readableBytesView)
            return bytes.isEmpty ? nil : (file.filename, bytes)
        }
        guard !candidates.isEmpty else { return }
        do {
            for candidate in candidates {
                try ContentAttachmentStore.validate(bytes: candidate.bytes, originalName: candidate.name)
            }
        } catch let error as ContentAttachmentStore.StoreError {
            throw WebAssignmentError.invalidParameter(name: "attachmentFiles", reason: error.reason)
        }
        var attachments = item.attachments
        var nextOrder = (attachments.map(\.sortOrder).max() ?? 0) + 1
        for candidate in candidates {
            let attachment = try await ContentAttachmentStore.store(
                bytes: candidate.bytes, originalName: candidate.name, label: nil,
                sortOrder: nextOrder, itemID: itemID, on: req)
            attachments.append(attachment)
            nextOrder += 1
        }
        item.attachments = attachments
        try await item.save(on: req.db)
    }

    /// Next sort order in the content-item lane of `(course, section)`.
    private func nextContentItemSortOrder(
        courseID: UUID, sectionID: UUID?, db: any Database
    ) async throws -> Int {
        let query = APICourseContentItem.query(on: db).filter(\.$courseID == courseID)
        if let sectionID {
            query.filter(\.$sectionID == sectionID)
        } else {
            query.filter(\.$sectionID == nil)
        }
        let maxOrder = try await query.max(\.$sortOrder) ?? 0
        return maxOrder + 1
    }

    /// Builds `[ContentLink]` from parallel form arrays, dropping fully-blank
    /// rows, defaulting a blank label to the URL, and rejecting unsafe schemes
    /// (only http(s) and site-relative `/…` links are allowed — the values are
    /// rendered as `href`s, so `javascript:` / `data:` are refused).
    private func buildContentLinks(labels: [String], urls: [String]) throws -> [ContentLink] {
        var links: [ContentLink] = []
        let count = Swift.max(labels.count, urls.count)
        for i in 0..<count {
            let label =
                (i < labels.count ? labels[i] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            let url =
                (i < urls.count ? urls[i] : "").trimmingCharacters(in: .whitespacesAndNewlines)
            if label.isEmpty, url.isEmpty { continue }
            guard !url.isEmpty else {
                throw WebAssignmentError.invalidParameter(
                    name: "links", reason: "The link labelled \"\(label)\" is missing a URL.")
            }
            guard isSafeLinkURL(url) else {
                throw WebAssignmentError.invalidParameter(
                    name: "links",
                    reason: "Link URL \"\(url)\" must be an http(s) or site-relative (/…) URL.")
            }
            links.append(ContentLink(label: label.isEmpty ? url : label, url: url))
        }
        return links
    }

    private func isSafeLinkURL(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || url.hasPrefix("/")
    }

    /// Trims and maps an empty string to nil for optional text fields.
    private func normalizedOptional(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty
        else { return nil }
        return trimmed
    }
}
