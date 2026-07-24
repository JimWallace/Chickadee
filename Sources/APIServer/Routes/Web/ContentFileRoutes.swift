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
    func boot(routes: RoutesBuilder) throws {
        routes.get("content-files", ":itemID", ":attachmentID", use: downloadContentFile)
    }

    @Sendable
    func downloadContentFile(req: Request) async throws -> Response {
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

        let response = try await req.fileio.asyncStreamFile(at: path)
        // The on-disk name is an extensionless UUID, so set the type + download
        // name from the stored original filename.
        let ext = (attachment.originalName as NSString).pathExtension.lowercased()
        response.headers.contentType = HTTPMediaType.fileExtension(ext) ?? .binary
        let safeDownloadName =
            attachment.originalName
            .replacingOccurrences(of: "\"", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: "\n", with: "")
        response.headers.replaceOrAdd(
            name: .contentDisposition, value: "attachment; filename=\"\(safeDownloadName)\"")
        return response
    }
}
