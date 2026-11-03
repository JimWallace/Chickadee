// APIServer/Routes/Web/CourseBundleRoutes.swift
//
// Course bundle export and import.
//
//   GET  /admin/courses/:courseID/export   — stream a bundle ZIP for download
//   POST /admin/courses/import             — accept an uploaded bundle ZIP
//
// Both routes require admin role (enforced in routes.swift).
//
// The handlers check the caller, parse the request and stream the response.
// `CourseBundleService` owns the bundle format, the export pipeline and the
// import transaction (#2774).

import Core
import Elementary
import Fluent
import Foundation
import Vapor

struct CourseBundleRoutes: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let admin = routes.grouped("admin")
        admin.get("courses", ":courseID", "export", use: exportCourse)
        admin.on(
            .POST, "courses", "import",
            // A real bundle is testsetup zips + every submission for the
            // course; the 10 MB default made importing Chickadee's own
            // exports impossible (#1158).
            //
            // This is a backstop, not the effective limit. Behind a reverse
            // proxy the proxy's own cap applies first and rejects the body
            // before the app is reached — `client_max_body_size` in
            // deploy/nginx.conf, deliberately set well below this. Raise that
            // too when a deployment genuinely needs a larger import.
            body: .collect(maxSize: "2gb"),
            use: importCourse)
    }

    // MARK: - GET /admin/courses/:courseID/export

    @Sendable
    func exportCourse(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw AppError.forbidden(action: "export a course") }

        guard let courseIDStr = req.parameters.get("courseID"),
            let courseUUID = UUID(uuidString: courseIDStr),
            let course = try await APICourse.find(courseUUID, on: req.db)
        else { throw AppError.notFound(resource: "Course") }

        let bundle = try await CourseBundleService.exportBundle(
            course: course, courseID: courseUUID, caller: caller,
            app: req.application, db: req.db, logger: req.logger)

        await AuditLogger.record(
            action: .courseBundleExported,
            targetType: .course,
            targetID: courseIDStr,
            metadata: ["course_code": course.code],
            on: req
        )
        do {
            return try await streamTemporaryZip(
                req: req, zipPath: bundle.zipPath, downloadName: bundle.downloadName)
        } catch {
            try? FileManager.default.removeItem(atPath: bundle.zipPath)
            throw error
        }
    }

    // MARK: - POST /admin/courses/import

    @Sendable
    func importCourse(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw AppError.forbidden(action: "import a course") }

        let uploadBuffer = try await readUploadedBundleBuffer(req: req)

        let tmpZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-import-\(UUID().uuidString).zip").path
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-import-ex-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(atPath: tmpZipPath)
            try? FileManager.default.removeItem(at: extractDir)
        }

        try await extractUploadedBundle(
            req: req, buffer: uploadBuffer, tmpZipPath: tmpZipPath, extractDir: extractDir)

        let tally = try await CourseBundleService.importExtractedBundle(
            extractDir: extractDir, app: req.application, db: req.db)

        await AuditLogger.record(
            action: .courseBundleImported,
            targetType: .course,
            targetID: tally.courseID.uuidString,
            metadata: [
                "course_code": tally.courseCode,
                "test_setups": String(tally.testSetupsImported),
                "assignments": String(tally.assignmentsImported),
                "submissions": String(tally.submissionsImported),
            ],
            on: req
        )
        return try await renderImportResult(req: req, tally: tally)
    }

    /// Forwards to `CourseBundleService.performImportTransaction`. The import
    /// tests call it through the route type.
    func performImportTransaction(
        app: Application,
        db: any Database,
        manifest: CourseBundleManifest,
        dirs: BundleImportDirectories
    ) async throws -> ImportTally {
        try await CourseBundleService.performImportTransaction(
            app: app, db: db, manifest: manifest, dirs: dirs)
    }

    // ── Receive the uploaded bundle ───────────────────────────────────

    private func readUploadedBundleBuffer(req: Request) async throws -> ByteBuffer {
        struct BundleUpload: Content {
            let file: File
        }
        let upload = try await req.decodeContent(BundleUpload.self)
        guard upload.file.data.readableBytes > 0 else {
            throw AppError.badRequest(reason: "Empty bundle upload")
        }
        // The ByteBuffer goes straight to fileio — the old
        // ByteBuffer → [UInt8] → Data chain held three full copies of a
        // potentially multi-hundred-MB bundle in heap at once (#1158).
        return upload.file.data
    }

    // ── Save to temp file and extract ─────────────────────────────────

    private func extractUploadedBundle(
        req: Request, buffer: ByteBuffer, tmpZipPath: String, extractDir: URL
    ) async throws {
        try await req.fileio.writeFile(buffer, at: tmpZipPath)
        try await extractZipArchive(zipPath: tmpZipPath, into: extractDir)
    }

    // ── Render result page ────────────────────────────────────────────

    private func renderImportResult(req: Request, tally: ImportTally) async throws -> Response {
        try await HTMLResponse {
            AdminImportResultPage(page: PageRequestContext(request: req), tally: tally)
        }.encodeResponse(for: req)
    }
}
