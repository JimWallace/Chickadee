// APIServer/Routes/Web/ContentFileRoutes.swift
//
// Serves hosted file attachments on ungraded course content items to enrolled
// students (and staff/admin), gated the same way support-file downloads are:
// the caller must be enrolled in the item's course, and a draft (unpublished)
// item's files are staff-only. Registered in the authenticated group (not the
// /instructor group) so students can download.
//
// Attachments are stored under a server-generated UUID name at
// contentFilesDirectory/<itemID>/<attachmentID>, so the path is never built
// from an untrusted filename; the download name + Content-Type come from the
// attachment's stored metadata.

import Core
import Fluent
import Foundation
import Vapor

struct ContentFileRoutes: RouteCollection {
    /// What a lookup yields once every gate has passed.
    private struct ResolvedAttachment {
        let attachment: ContentAttachment
        let path: String
        /// Lower-cased extension of the stored original filename.
        let ext: String
        /// The original filename with header-breaking characters removed.
        let safeName: String
    }

    func boot(routes: RoutesBuilder) throws {
        routes.get("content-files", ":itemID", ":attachmentID", use: downloadContentFile)
        routes.get("content-files", ":itemID", ":attachmentID", "view", use: viewContentFile)
    }

    /// The one lookup both handlers use, so the gates cannot drift apart:
    /// params → item → enrollment → draft gate → attachment → on-disk path.
    private func resolveAttachment(req: Request) async throws -> ResolvedAttachment {
        let caller = try req.auth.require(APIUser.self)
        guard let itemRaw = req.parameters.get("itemID"), let itemID = UUID(uuidString: itemRaw),
            let attachRaw = req.parameters.get("attachmentID"),
            let attachmentID = UUID(uuidString: attachRaw),
            let item = try await APICourseContentItem.find(itemID, on: req.db)
        else { throw Abort(.notFound) }

        // Enrolled members of the item's course only (admins bypass inside the
        // helper); mirrors downloadSupportFile.
        try await requireCourseEnrollment(caller: caller, courseID: item.courseID, db: req.db)

        // A draft item's files are staff-only, matching the dashboard visibility
        // rule (students never see an unpublished item, so they can't have its
        // link — but gate the bytes directly rather than trusting that).
        if !item.isPublished {
            let isStaff = try await isCourseStaff(caller, inCourse: item.courseID, db: req.db)
            guard isStaff else { throw Abort(.notFound) }
        }

        guard let attachment = item.attachments.first(where: { $0.id == attachmentID }) else {
            throw Abort(.notFound)
        }
        let path = ContentAttachmentStore.path(
            req.application, itemID: itemID, attachmentID: attachmentID)
        guard FileManager.default.fileExists(atPath: path) else { throw Abort(.notFound) }

        let safeName =
            attachment.originalName
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        return ResolvedAttachment(
            attachment: attachment, path: path,
            ext: (attachment.originalName as NSString).pathExtension.lowercased(),
            safeName: safeName)
    }

    @Sendable
    func downloadContentFile(req: Request) async throws -> Response {
        let resolved = try await resolveAttachment(req: req)
        let response = try await req.fileio.asyncStreamFile(at: resolved.path)
        // The on-disk name is an extensionless UUID, so set the type + download
        // name from the stored original filename.
        response.headers.contentType = HTTPMediaType.fileExtension(resolved.ext) ?? .binary
        response.headers.replaceOrAdd(
            name: .contentDisposition, value: "attachment; filename=\"\(resolved.safeName)\"")
        return response
    }

    /// Opens a PDF in the browser.  PDF only: the stored extension must be
    /// `pdf` AND the file must begin with `%PDF-`.  Anything else is a 404, never
    /// a redirect to the download — a view URL must not unexpectedly save a
    /// file.  The allowlist is never extended to HTML, SVG or anything
    /// scriptable, and no `Content-Security-Policy: sandbox` is added: Chrome's
    /// built-in PDF viewer does not render inside a sandboxed document.
    @Sendable
    func viewContentFile(req: Request) async throws -> Response {
        let resolved = try await resolveAttachment(req: req)
        guard resolved.ext == "pdf", Self.beginsWithPDFMagic(atPath: resolved.path) else {
            throw Abort(.notFound)
        }
        let response = try await req.fileio.asyncStreamFile(at: resolved.path)
        response.headers.contentType = .pdf
        response.headers.replaceOrAdd(
            name: .contentDisposition, value: "inline; filename=\"\(resolved.safeName)\"")
        response.headers.replaceOrAdd(name: "X-Content-Type-Options", value: "nosniff")
        response.headers.replaceOrAdd(name: .cacheControl, value: "private")
        return response
    }

    private static func beginsWithPDFMagic(atPath path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 5)) ?? Data()
        return head == Data("%PDF-".utf8)
    }
}
