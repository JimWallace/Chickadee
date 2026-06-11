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
        admin.post("courses", "import", use: importCourse)
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
        try writeExportStaging(
            stagingDir: stagingDir, manifest: manifest, data: data, logger: req.logger)

        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let safeCourseCode = course.code.replacingOccurrences(of: "/", with: "-")
        let bundleName = "chickadee-bundle-\(safeCourseCode)-\(dateStr).zip"
        let bundleZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleName).path

        defer {
            try? FileManager.default.removeItem(atPath: bundleZipPath)
        }

        try await createZipArchive(sourceDir: stagingDir, outputPath: bundleZipPath)

        await AuditLogger.record(
            action: .courseBundleExported,
            targetType: .course,
            targetID: courseIDStr,
            metadata: ["course_code": course.code],
            on: req
        )
        return try streamExportZip(bundleZipPath: bundleZipPath, bundleName: bundleName)
    }

    // ── 1. Load all course data ────────────────────────────────────────

    private func loadExportData(courseUUID: UUID, on db: Database) async throws -> ExportData {
        let testSetups = try await APITestSetup.query(on: db)
            .filter(\.$courseID == courseUUID)
            .all()

        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseUUID)
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

        return ExportData(
            testSetups: testSetups,
            assignments: assignments,
            enrolledUserIDs: enrolledUserIDs,
            allUsers: Array(allUsers),
            submissions: submissions,
            results: results
        )
    }

    // ── 2. Assign bundleIDs ────────────────────────────────────────────

    private func assignExportBundleIDs(data: ExportData) -> ExportBundleIDs {
        var userBundleIDByUUID: [UUID: String] = [:]
        var setupBundleIDByID: [String: String] = [:]
        var assignBundleIDByID: [UUID: String] = [:]
        var subBundleIDByID: [String: String] = [:]

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

        return ExportBundleIDs(
            userBundleIDByUUID: userBundleIDByUUID,
            setupBundleIDByID: setupBundleIDByID,
            assignBundleIDByID: assignBundleIDByID,
            subBundleIDByID: subBundleIDByID
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

        let bundledAssignments = data.assignments.compactMap { a -> BundledAssignment? in
            guard let aid = a.id, let bid = bundleIDs.assignBundleIDByID[aid],
                let setupBid = bundleIDs.setupBundleIDByID[a.testSetupID]
            else { return nil }
            return BundledAssignment(
                bundleID: bid,
                title: a.title,
                dueAt: a.dueAt,
                startsAt: a.startsAt,
                isOpen: a.isOpen,
                visibility: a.visibility,
                sortOrder: a.sortOrder,
                testSetupBundleID: setupBid
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
            guard let subBid = bundleIDs.subBundleIDByID[r.submissionID] else { return nil }
            return BundledResult(
                submissionBundleID: subBid,
                collectionJSON: r.collectionJSON,
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
                enrollmentMode: course.enrollmentMode),
            users: bundledUsers,
            enrolledUserBundleIDs: enrolledBundleIDs,
            assignments: bundledAssignments,
            testSetups: bundledSetups,
            submissions: bundledSubmissions,
            results: bundledResults
        )
    }

    // ── 4. Write staging directory ─────────────────────────────────────

    private func writeExportStaging(
        stagingDir: URL,
        manifest: CourseBundleManifest,
        data: ExportData,
        logger: Logger
    ) throws {
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stagingDir.appendingPathComponent("testsetups"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: stagingDir.appendingPathComponent("submissions"), withIntermediateDirectories: true)

        // Write bundle.json
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        try manifestData.write(to: stagingDir.appendingPathComponent("bundle.json"))

        // Copy test setup zips
        for setup in data.testSetups {
            guard let sid = setup.id else { continue }
            let src = URL(fileURLWithPath: setup.zipPath)
            let dst = stagingDir.appendingPathComponent("testsetups/\(sid).zip")
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dst)
            } else {
                logger.warning("Export: test setup zip missing at \(src.path), skipping")
            }
        }

        // Copy submission files
        for sub in data.submissions {
            let src = URL(fileURLWithPath: sub.zipPath)
            let onDiskName = src.lastPathComponent
            let dst = stagingDir.appendingPathComponent("submissions/\(onDiskName)")
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dst)
            } else {
                logger.warning("Export: submission file missing at \(src.path), skipping")
            }
        }
    }

    // ── 6. Stream the ZIP to the browser ──────────────────────────────

    private func streamExportZip(bundleZipPath: String, bundleName: String) throws -> Response {
        guard let zipData = try? Data(contentsOf: URL(fileURLWithPath: bundleZipPath)) else {
            throw AppError.internalFailure(reason: "Failed to read bundle ZIP")
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/zip")
        headers.add(
            name: .contentDisposition,
            value: "attachment; filename=\"\(bundleName)\"")
        headers.add(name: .contentLength, value: "\(zipData.count)")

        return Response(status: .ok, headers: headers, body: .init(data: zipData))
    }
}

// MARK: - Export data carriers

/// All the data fetched from the database for an export.
private struct ExportData {
    let testSetups: [APITestSetup]
    let assignments: [APIAssignment]
    let enrolledUserIDs: [UUID]
    let allUsers: [APIUser]
    let submissions: [APISubmission]
    let results: [APIResult]
}

/// Maps from live DB ids to in-bundle synthetic identifiers used for cross-references.
private struct ExportBundleIDs {
    let userBundleIDByUUID: [UUID: String]
    let setupBundleIDByID: [String: String]
    let assignBundleIDByID: [UUID: String]
    let subBundleIDByID: [String: String]
}
