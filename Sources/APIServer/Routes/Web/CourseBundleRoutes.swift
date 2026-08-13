// APIServer/Routes/Web/CourseBundleRoutes.swift
//
// Course bundle export and import.
//
//   GET  /admin/courses/:courseID/export   — stream a bundle ZIP for download
//   POST /admin/courses/import             — accept an uploaded bundle ZIP
//
// Both routes require admin role (enforced in routes.swift).
//
// Bundle format (schemaVersion 1):
//   bundle.json              — CourseBundleManifest (ISO8601 dates)
//   testsetups/<id>.zip      — instructor test-setup archives
//   submissions/<id>.<ext>   — student submission files
//   content/<attachmentID>   — content-item hosted file attachments
//
// This file holds boot + the export pipeline; the import handler and its
// phase helpers live in CourseBundleRoutes+Import.swift.

import Core
import Fluent
import Foundation
import Vapor

struct CourseBundleRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
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
        guard caller.isAdmin else { throw Abort(.forbidden) }

        guard let courseIDStr = req.parameters.get("courseID"),
            let courseUUID = UUID(uuidString: courseIDStr),
            let course = try await APICourse.find(courseUUID, on: req.db)
        else { throw AppError.notFound(resource: "Course") }

        let data = try await loadExportData(courseUUID: courseUUID, on: req.db)
        let bundleIDs = assignExportBundleIDs(data: data)
        let manifest = buildExportManifest(
            course: course, caller: caller, data: data, bundleIDs: bundleIDs)

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-export-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
        }
        // Staging copies every setup zip + submission file — synchronous bulk
        // file I/O, so run it on the thread pool (#1158). Primitives only in
        // the closure: Fluent models aren't Sendable.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        let setupCopies = data.testSetups.compactMap { setup in
            setup.id.map { (id: $0, zipPath: setup.zipPath) }
        }
        let submissionPaths = data.submissions.map(\.zipPath)
        // Hosted content-item attachment files: (on-disk src, in-bundle name).
        // Extracted to primitives here so the thread-pool closure captures no
        // Fluent models (#1158).
        let app = req.application
        let contentFileCopies: [(src: String, bundleName: String)] = data.contentItems.flatMap { item in
            guard let itemID = item.id else { return [(src: String, bundleName: String)]() }
            return item.attachments.map { att in
                (
                    src: ContentAttachmentStore.path(app, itemID: itemID, attachmentID: att.id),
                    bundleName: "content/\(att.id.uuidString)"
                )
            }
        }
        let logger = req.logger
        try await runBlocking(on: req) {
            try writeExportStaging(
                stagingDir: stagingDir,
                manifestData: manifestData,
                setupCopies: setupCopies,
                submissionPaths: submissionPaths,
                contentFileCopies: contentFileCopies,
                logger: logger)
        }

        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let safeCourseCode = course.code.replacingOccurrences(of: "/", with: "-")
        let bundleName = "chickadee-bundle-\(safeCourseCode)-\(dateStr).zip"
        let bundleZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleName).path

        // No defer here: the response body streams AFTER this handler
        // returns, so the temp zip must outlive the handler. streamExportZip
        // deletes it in the stream's onCompleted hook; the catch below covers
        // the paths where no stream ever starts.
        try await createZipArchive(sourceDir: stagingDir, outputPath: bundleZipPath)

        await AuditLogger.record(
            action: .courseBundleExported,
            targetType: .course,
            targetID: courseIDStr,
            metadata: ["course_code": course.code],
            on: req
        )
        do {
            return try await streamExportZip(
                req: req, bundleZipPath: bundleZipPath, bundleName: bundleName)
        } catch {
            try? FileManager.default.removeItem(atPath: bundleZipPath)
            throw error
        }
    }

    // ── 1. Load all course data ────────────────────────────────────────

    private func loadExportData(courseUUID: UUID, on db: Database) async throws -> ExportData {
        let testSetups = try await APITestSetup.query(on: db)
            .filter(\.$courseID == courseUUID)
            .all()

        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseUUID)
            .all()

        let sections = try await APICourseSection.query(on: db)
            .filter(\.$courseID == courseUUID)
            .sort(\.$sortOrder)
            .all()

        let contentItems = try await APICourseContentItem.query(on: db)
            .filter(\.$courseID == courseUUID)
            .sort(\.$sortOrder)
            .all()

        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseUUID)
            .all()

        let enrolledUserIDs = enrollments.map(\.userID)
        var enrolledUsers: [APIUser] = []
        if !enrolledUserIDs.isEmpty {
            enrolledUsers = try await APIUser.query(on: db)
                .filter(\.$id ~~ enrolledUserIDs)
                .all()
        }

        let setupIDs = testSetups.compactMap(\.id)
        var submissions: [APISubmission] = []
        if !setupIDs.isEmpty {
            submissions = try await APISubmission.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs)
                .filter(\.$kind == APISubmission.Kind.student)
                .all()
        }

        // Collect unique user UUIDs from submissions not already in enrolled set.
        let submitterIDs = submissions.compactMap(\.userID)
            .filter { !enrolledUserIDs.contains($0) }
        var additionalUsers: [APIUser] = []
        if !submitterIDs.isEmpty {
            let uniqueIDs = Array(Set(submitterIDs))
            additionalUsers = try await APIUser.query(on: db)
                .filter(\.$id ~~ uniqueIDs)
                .all()
        }
        let allUsers = (enrolledUsers + additionalUsers)
            .reduce(into: [UUID: APIUser]()) { dict, user in
                if let id = user.id { dict[id] = user }
            }
            .values
            .sorted { ($0.username) < ($1.username) }

        let subIDs = submissions.compactMap(\.id)
        var results: [APIResult] = []
        if !subIDs.isEmpty {
            results = try await APIResult.query(on: db)
                .filter(\.$submissionID ~~ subIDs)
                .all()
        }
        // The bundle carries the full collection blob per result (#1173:
        // it lives in the result_collections side table, not on the row).
        let resultCollectionJSONByID = try await collectionJSONByResultID(
            for: results.compactMap(\.id), on: db)

        return ExportData(
            testSetups: testSetups,
            assignments: assignments,
            sections: sections,
            contentItems: contentItems,
            enrolledUserIDs: enrolledUserIDs,
            allUsers: Array(allUsers),
            submissions: submissions,
            results: results,
            resultCollectionJSONByID: resultCollectionJSONByID
        )
    }

    // ── 2. Assign bundleIDs ────────────────────────────────────────────

    private func assignExportBundleIDs(data: ExportData) -> ExportBundleIDs {
        var userBundleIDByUUID: [UUID: String] = [:]
        var setupBundleIDByID: [String: String] = [:]
        var assignBundleIDByID: [UUID: String] = [:]
        var subBundleIDByID: [String: String] = [:]
        var sectionBundleIDByUUID: [UUID: String] = [:]

        for (i, u) in data.allUsers.enumerated() {
            guard let uid = u.id else { continue }
            userBundleIDByUUID[uid] = "user_\(i + 1)"
        }
        for (i, s) in data.testSetups.enumerated() {
            guard let sid = s.id else { continue }
            setupBundleIDByID[sid] = "setup_\(i + 1)"
        }
        for (i, a) in data.assignments.enumerated() {
            guard let aid = a.id else { continue }
            assignBundleIDByID[aid] = "assign_\(i + 1)"
        }
        for (i, s) in data.submissions.enumerated() {
            guard let sid = s.id else { continue }
            subBundleIDByID[sid] = "sub_\(i + 1)"
        }
        for (i, sec) in data.sections.enumerated() {
            guard let secID = sec.id else { continue }
            sectionBundleIDByUUID[secID] = "section_\(i + 1)"
        }

        return ExportBundleIDs(
            userBundleIDByUUID: userBundleIDByUUID,
            setupBundleIDByID: setupBundleIDByID,
            assignBundleIDByID: assignBundleIDByID,
            subBundleIDByID: subBundleIDByID,
            sectionBundleIDByUUID: sectionBundleIDByUUID
        )
    }

    // ── 3. Build manifest ──────────────────────────────────────────────

    private func buildExportManifest(
        course: APICourse,
        caller: APIUser,
        data: ExportData,
        bundleIDs: ExportBundleIDs
    ) -> CourseBundleManifest {
        let bundledUsers = data.allUsers.compactMap { u -> BundledUser? in
            guard let uid = u.id, let bid = bundleIDs.userBundleIDByUUID[uid] else { return nil }
            return BundledUser(
                bundleID: bid, username: u.username,
                displayName: u.displayName, email: u.email,
                role: u.role)
        }

        let enrolledBundleIDs = data.enrolledUserIDs.compactMap { bundleIDs.userBundleIDByUUID[$0] }

        let bundledSetups = data.testSetups.compactMap { s -> BundledTestSetup? in
            guard let sid = s.id, let bid = bundleIDs.setupBundleIDByID[sid] else { return nil }
            return BundledTestSetup(
                bundleID: bid,
                originalID: sid,
                manifest: s.manifest,
                zipFilename: "testsetups/\(sid).zip"
            )
        }

        let bundledSections = data.sections.compactMap { sec -> BundledSection? in
            guard let secID = sec.id, let bid = bundleIDs.sectionBundleIDByUUID[secID] else {
                return nil
            }
            return BundledSection(
                bundleID: bid,
                name: sec.name,
                defaultGradingMode: sec.defaultGradingMode,
                sortOrder: sec.sortOrder
            )
        }

        let bundledContentItems = buildBundledContentItems(data: data, bundleIDs: bundleIDs)

        let bundledAssignments = data.assignments.compactMap { a -> BundledAssignment? in
            guard let aid = a.id, let bid = bundleIDs.assignBundleIDByID[aid],
                let setupBid = bundleIDs.setupBundleIDByID[a.testSetupID]
            else { return nil }
            return BundledAssignment(
                bundleID: bid,
                title: a.title,
                dueAt: a.dueAt,
                startsAt: a.startsAt,
                visibility: a.visibility,
                sortOrder: a.sortOrder,
                testSetupBundleID: setupBid,
                sectionBundleID: a.sectionID.flatMap { bundleIDs.sectionBundleIDByUUID[$0] }
            )
        }

        let bundledSubmissions = data.submissions.compactMap { sub -> BundledSubmission? in
            guard let sid = sub.id, let bid = bundleIDs.subBundleIDByID[sid],
                let setupBid = bundleIDs.setupBundleIDByID[sub.testSetupID]
            else { return nil }
            let userBid = sub.userID.flatMap { bundleIDs.userBundleIDByUUID[$0] } ?? "unknown"
            let onDiskName = URL(fileURLWithPath: sub.zipPath).lastPathComponent
            return BundledSubmission(
                bundleID: bid,
                userBundleID: userBid,
                testSetupBundleID: setupBid,
                attemptNumber: sub.attemptNumber ?? 1,
                submittedAt: sub.submittedAt,
                filename: sub.filename,
                submissionFilename: "submissions/\(onDiskName)"
            )
        }

        let bundledResults = data.results.compactMap { r -> BundledResult? in
            guard let subBid = bundleIDs.subBundleIDByID[r.submissionID],
                let rid = r.id,
                let collectionJSON = data.resultCollectionJSONByID[rid]
            else { return nil }
            return BundledResult(
                submissionBundleID: subBid,
                collectionJSON: collectionJSON,
                source: r.source ?? "worker",
                receivedAt: r.receivedAt
            )
        }

        return CourseBundleManifest(
            exportedAt: Date(),
            exportedBy: caller.username,
            chickadeeVersion: ChickadeeVersion.current,
            course: BundledCourse(
                code: course.code, name: course.name,
                enrollmentMode: course.enrollmentMode,
                slipDaysEnabled: course.slipDaysEnabled,
                slipDaysPerStudent: course.slipDaysPerStudent,
                slipDayExtensionHours: course.slipDayExtensionHours),
            users: bundledUsers,
            enrolledUserBundleIDs: enrolledBundleIDs,
            sections: bundledSections,
            contentItems: bundledContentItems,
            assignments: bundledAssignments,
            testSetups: bundledSetups,
            submissions: bundledSubmissions,
            results: bundledResults
        )
    }

    /// Maps each course content item to its bundle representation, nesting the
    /// attachment metadata. Each attachment's global UUID doubles as its unique
    /// bundle filename (`content/<id>`); the bytes are copied in
    /// writeExportStaging.
    private func buildBundledContentItems(
        data: ExportData,
        bundleIDs: ExportBundleIDs
    ) -> [BundledContentItem] {
        data.contentItems.map { item in
            let attachments = item.attachments.map { att in
                BundledAttachment(
                    originalName: att.originalName,
                    sizeBytes: att.sizeBytes,
                    label: att.label,
                    sortOrder: att.sortOrder,
                    bundleFilename: "content/\(att.id.uuidString)")
            }
            return BundledContentItem(
                sectionBundleID: item.sectionID.flatMap { bundleIDs.sectionBundleIDByUUID[$0] },
                title: item.title,
                kind: item.kind.rawValue,
                description: item.itemDescription,
                links: item.links,
                attachments: attachments.isEmpty ? nil : attachments,
                updatedLabel: item.updatedLabel,
                isPublished: item.isPublished,
                sortOrder: item.sortOrder
            )
        }
    }

    // ── 4. Write staging directory ─────────────────────────────────────

    // ── 6. Stream the ZIP to the browser ──────────────────────────────

    private func streamExportZip(
        req: Request, bundleZipPath: String, bundleName: String
    ) async throws -> Response {
        // Stream instead of buffering: a bundle holds every submission for
        // the course and routinely runs to hundreds of MB — the old
        // Data(contentsOf:) held all of it in heap per download (#1158).
        // The file is opened lazily when the body streams (after the handler
        // has returned), so the temp zip is deleted in onCompleted, not in a
        // handler defer — a defer fires before the first byte is read.
        let response = try await req.fileio.asyncStreamFile(at: bundleZipPath) { _ in
            try? FileManager.default.removeItem(atPath: bundleZipPath)
        }
        response.headers.replaceOrAdd(name: .contentType, value: "application/zip")
        response.headers.replaceOrAdd(
            name: .contentDisposition,
            value: "attachment; filename=\"\(bundleName)\"")
        return response
    }
}

// ── 4. Write staging directory ─────────────────────────────────────
//
// Free function over primitives so the export handler can run it on the
// thread pool without capturing non-Sendable Fluent models (#1158).
private func writeExportStaging(
    stagingDir: URL,
    manifestData: Data,
    setupCopies: [(id: String, zipPath: String)],
    submissionPaths: [String],
    contentFileCopies: [(src: String, bundleName: String)],
    logger: Logger
) throws {
    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: stagingDir.appendingPathComponent("testsetups"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: stagingDir.appendingPathComponent("submissions"), withIntermediateDirectories: true)
    if !contentFileCopies.isEmpty {
        try FileManager.default.createDirectory(
            at: stagingDir.appendingPathComponent("content"), withIntermediateDirectories: true)
    }

    try manifestData.write(to: stagingDir.appendingPathComponent("bundle.json"))

    for copy in contentFileCopies {
        let src = URL(fileURLWithPath: copy.src)
        let dst = stagingDir.appendingPathComponent(copy.bundleName)
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(at: src, to: dst)
        } else {
            logger.warning("Export: content attachment missing at \(src.path), skipping")
        }
    }

    for setup in setupCopies {
        let src = URL(fileURLWithPath: setup.zipPath)
        let dst = stagingDir.appendingPathComponent("testsetups/\(setup.id).zip")
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(at: src, to: dst)
        } else {
            logger.warning("Export: test setup zip missing at \(src.path), skipping")
        }
    }

    for zipPath in submissionPaths {
        let src = URL(fileURLWithPath: zipPath)
        let onDiskName = src.lastPathComponent
        let dst = stagingDir.appendingPathComponent("submissions/\(onDiskName)")
        if FileManager.default.fileExists(atPath: src.path) {
            try FileManager.default.copyItem(at: src, to: dst)
        } else {
            logger.warning("Export: submission file missing at \(src.path), skipping")
        }
    }
}

// MARK: - Export data carriers

/// All the data fetched from the database for an export.
private struct ExportData {
    let testSetups: [APITestSetup]
    let assignments: [APIAssignment]
    let sections: [APICourseSection]
    let contentItems: [APICourseContentItem]
    let enrolledUserIDs: [UUID]
    let allUsers: [APIUser]
    let submissions: [APISubmission]
    let results: [APIResult]
    /// Collection blob per result id, batch-fetched from the side table.
    let resultCollectionJSONByID: [String: String]
}

/// Maps from live DB ids to in-bundle synthetic identifiers used for cross-references.
private struct ExportBundleIDs {
    let userBundleIDByUUID: [UUID: String]
    let setupBundleIDByID: [String: String]
    let assignBundleIDByID: [UUID: String]
    let subBundleIDByID: [String: String]
    let sectionBundleIDByUUID: [UUID: String]
}
