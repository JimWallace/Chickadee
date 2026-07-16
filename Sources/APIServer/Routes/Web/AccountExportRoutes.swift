// APIServer/Routes/Web/AccountExportRoutes.swift
//
// Personal-data export endpoints (#557 — FIPPA / PIPEDA subject access),
// available to any authenticated user and always scoped to their own data
// (there is no way to name another user's export).
//
//   POST /account/export           → reset/create the user's export row,
//                                    kick off async generation → /account
//   GET  /account/export/status    → tiny JSON poll for the account page
//   GET  /account/export/download  → stream the finished zip
//
// Rate limiting is one export per day per user, enforced against the
// row's `requestedAt` (DB-backed, so it holds across processes).  Both
// the request and the download are audit-logged.

import Fluent
import Foundation
import Vapor

struct AccountExportRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        routes.post("account", "export", use: requestExport)
        routes.get("account", "export", "status", use: exportStatus)
        routes.get("account", "export", "download", use: downloadExport)
    }

    // MARK: - POST /account/export

    @Sendable
    func requestExport(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        let now = Date()

        let existing = try await APIDataExport.query(on: req.db)
            .filter(\.$userID == userID)
            .first()
        if !dataExportCanBeRequested(existing, now: now) {
            // A live pending row means the export is already on its way —
            // report progress rather than an error.
            if existing?.statusValue == .pending {
                return req.redirect(to: "/account?exportNotice=in_progress")
            }
            return req.redirect(to: "/account?exportError=rate_limited")
        }

        // One row per user: reset the existing row in place (or create the
        // first one).  The previous zip is removed up front so a stale
        // archive can't be downloaded while its replacement generates.
        let export = existing ?? APIDataExport(userID: userID, requestedAt: now)
        export.setStatus(.pending)
        export.requestedAt = now
        export.completedAt = nil
        export.fileSizeBytes = nil
        export.failureReason = nil
        if let previousZip = export.zipPath {
            try? FileManager.default.removeItem(atPath: previousZip)
            export.zipPath = nil
        }
        try await export.save(on: req.db)

        await AuditLogger.record(
            action: .userDataExportRequested,
            targetType: .user,
            targetID: userID.uuidString,
            on: req
        )

        await req.application.dataExportManager.startExport(
            exportID: try export.requireID(), userID: userID, app: req.application)
        return req.redirect(to: "/account?exportNotice=started")
    }

    // MARK: - GET /account/export/status

    @Sendable
    func exportStatus(req: Request) async throws -> DataExportStatusResponse {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()
        let export = try await APIDataExport.query(on: req.db)
            .filter(\.$userID == userID)
            .first()
        return DataExportStatusResponse(status: export?.statusValue?.rawValue ?? "none")
    }

    // MARK: - GET /account/export/download

    @Sendable
    func downloadExport(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        let userID = try user.requireID()

        guard
            let export = try await APIDataExport.query(on: req.db)
                .filter(\.$userID == userID)
                .first(),
            export.statusValue == .complete,
            let zipPath = export.zipPath,
            FileManager.default.fileExists(atPath: zipPath)
        else {
            return req.redirect(to: "/account?exportError=not_ready")
        }

        // FIPPA accountability: record where the bundled personal data went
        // (the actor is the owner, so the logged IP/user-agent are theirs).
        await AuditLogger.record(
            action: .userDataExportDownloaded,
            targetType: .user,
            targetID: userID.uuidString,
            on: req
        )

        let stamp = downloadDateStamp(export.completedAt ?? Date())
        let downloadName =
            "chickadee-data-export-\(sanitizedDownloadComponent(user.username))-\(stamp).zip"
        let response = try await req.fileio.asyncStreamFile(at: zipPath)
        response.headers.replaceOrAdd(name: .contentType, value: "application/zip")
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(downloadName)\"")
        return response
    }
}

struct DataExportStatusResponse: Content {
    let status: String
}

/// yyyy-MM-dd (UTC) for the download filename.
private func downloadDateStamp(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "UTC")
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter.string(from: date)
}

/// Restricts a username to header-safe ASCII for the Content-Disposition
/// filename; anything else becomes "-".
private func sanitizedDownloadComponent(_ raw: String) -> String {
    let mapped = raw.map { ch -> Character in
        if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "-" || ch == "_") {
            return ch
        }
        return "-"
    }
    let cleaned = String(mapped)
    return cleaned.isEmpty ? "user" : cleaned
}
