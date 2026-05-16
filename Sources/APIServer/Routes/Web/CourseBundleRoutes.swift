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
// Import rules:
//   - Same course code, active     → reject with error message
//   - Same course code, archived   → create a second course (admin can rename)
//   - Unknown course code          → create fresh
//   - Users: match by username or create placeholder (inert until password reset)
//   - All DB IDs are regenerated; bundleIDs are internal cross-references only.
//   - validationStatus is NOT imported; assignments land as "pending" validation.

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
        else { throw Abort(.notFound, reason: "Course not found") }

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
                isOpen: a.isOpen,
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
            throw Abort(.internalServerError, reason: "Failed to read bundle ZIP")
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/zip")
        headers.add(
            name: .contentDisposition,
            value: "attachment; filename=\"\(bundleName)\"")
        headers.add(name: .contentLength, value: "\(zipData.count)")

        return Response(status: .ok, headers: headers, body: .init(data: zipData))
    }

    // MARK: - POST /admin/courses/import

    @Sendable
    func importCourse(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw Abort(.forbidden) }

        let fileBytes = try readUploadedBundleBytes(req: req)

        let tmpZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-import-\(UUID().uuidString).zip").path
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-import-ex-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(atPath: tmpZipPath)
            try? FileManager.default.removeItem(at: extractDir)
        }

        try await extractUploadedBundle(
            fileBytes: fileBytes, tmpZipPath: tmpZipPath, extractDir: extractDir)

        let manifest = try parseBundleManifest(extractDir: extractDir)

        try validateBundleFiles(manifest: manifest, extractDir: extractDir)

        let setupsDir = req.application.testSetupsDirectory
        let subsDir = req.application.submissionsDirectory

        let tally = try await performImportTransaction(
            db: req.db,
            manifest: manifest,
            extractDir: extractDir,
            setupsDir: setupsDir,
            subsDir: subsDir
        )

        return try await renderImportResult(req: req, tally: tally)
    }

    // ── 1. Receive the uploaded bundle ────────────────────────────────

    private func readUploadedBundleBytes(req: Request) throws -> [UInt8] {
        struct BundleUpload: Content {
            let file: File
        }
        let upload = try req.content.decode(BundleUpload.self)
        var buffer = upload.file.data
        guard buffer.readableBytes > 0,
            let fileBytes = buffer.readBytes(length: buffer.readableBytes)
        else {
            throw Abort(.badRequest, reason: "Empty bundle upload")
        }
        return fileBytes
    }

    // ── 2. Save to temp file and extract ─────────────────────────────

    private func extractUploadedBundle(
        fileBytes: [UInt8], tmpZipPath: String, extractDir: URL
    ) async throws {
        try Data(fileBytes).write(to: URL(fileURLWithPath: tmpZipPath))
        try await extractZipArchive(zipPath: tmpZipPath, into: extractDir)
    }

    // ── 3. Parse bundle.json ──────────────────────────────────────────

    private func parseBundleManifest(extractDir: URL) throws -> CourseBundleManifest {
        let bundleJSONPath = extractDir.appendingPathComponent("bundle.json")
        guard let manifestData = try? Data(contentsOf: bundleJSONPath) else {
            throw Abort(.badRequest, reason: "bundle.json not found in archive")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: CourseBundleManifest
        do {
            manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)
        } catch {
            throw Abort(.badRequest, reason: "Invalid bundle.json: \(error)")
        }

        guard manifest.schemaVersion == 1 else {
            throw Abort(
                .badRequest,
                reason: "Unsupported bundle schemaVersion \(manifest.schemaVersion); expected 1")
        }

        return manifest
    }

    // ── 4. Validate all referenced files exist ────────────────────────

    private func validateBundleFiles(
        manifest: CourseBundleManifest, extractDir: URL
    ) throws {
        for setup in manifest.testSetups {
            let path = extractDir.appendingPathComponent(setup.zipFilename)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw Abort(
                    .badRequest,
                    reason: "Bundle is missing test setup file: \(setup.zipFilename)")
            }
        }
        for sub in manifest.submissions {
            let path = extractDir.appendingPathComponent(sub.submissionFilename)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw Abort(
                    .badRequest,
                    reason: "Bundle is missing submission file: \(sub.submissionFilename)")
            }
        }
    }

    // ── 6. Transactional import ───────────────────────────────────────
    // The conflict check (formerly step 5) is now the first thing inside the
    // transaction so there is no outstanding req.db cursor before the transaction
    // begins. On SQLite this prevents "busy: cannot commit transaction — SQL
    // statements in progress" errors caused by an open cursor from a pre-transaction
    // query lingering when the COMMIT fires.
    //
    // Returns a tally from the closure to avoid captured-var mutation warnings
    // (errors in Swift 6 strict mode).

    private func performImportTransaction(
        db: Database,
        manifest: CourseBundleManifest,
        extractDir: URL,
        setupsDir: String,
        subsDir: String
    ) async throws -> ImportTally {
        try await db.transaction { (db) -> ImportTally in
            // 6a. Check for course code conflicts (moved inside transaction)
            let existingCourse = try await APICourse.query(on: db)
                .filter(\.$code == manifest.course.code)
                .first()
            if let existing = existingCourse, !existing.isArchived {
                throw Abort(
                    .conflict,
                    reason: """
                        A course with code "\(manifest.course.code)" already exists and is active. \
                        Archive it first, then re-import.
                        """)
            }

            var t = ImportTally(
                courseID: UUID(),
                courseCode: manifest.course.code,
                courseName: manifest.course.name
            )

            // 6b. Create course
            let importedMode = bundledCourseEnrollmentMode(manifest.course)
            let newCourse = APICourse(
                code: manifest.course.code, name: manifest.course.name,
                enrollmentMode: importedMode)
            try await newCourse.save(on: db)
            guard let newCourseID = newCourse.id else {
                throw Abort(.internalServerError, reason: "Created course missing id after save")
            }
            t.courseID = newCourseID
            t.courseCode = newCourse.code
            t.courseName = newCourse.name

            // 6c. Resolve users → userIDMap[bundleID] = live UUID
            let userIDMap = try await importBundledUsers(manifest: manifest, db: db, tally: &t)

            // 6d. Create enrollments for enrolled users
            try await importBundledEnrollments(
                manifest: manifest, userIDMap: userIDMap, courseID: t.courseID, db: db)

            // 6e. Create test setups → setupIDMap[bundleID] = new live ID
            let setupIDMap = try await importBundledTestSetups(
                manifest: manifest, extractDir: extractDir, setupsDir: setupsDir,
                courseID: t.courseID, db: db, tally: &t)

            // 6f. Create assignments
            try await importBundledAssignments(
                manifest: manifest, setupIDMap: setupIDMap, courseID: t.courseID,
                db: db, tally: &t)

            // 6g. Create submissions → subIDMap[bundleID] = new live ID
            let subIDMap = try await importBundledSubmissions(
                manifest: manifest, extractDir: extractDir, subsDir: subsDir,
                idMaps: ImportIDMaps(userIDMap: userIDMap, setupIDMap: setupIDMap),
                db: db, tally: &t)

            // 6h. Create results
            try await importBundledResults(
                manifest: manifest, subIDMap: subIDMap, db: db, tally: &t)

            return t
        }
    }

    // ── 8. Render result page ─────────────────────────────────────────

    private func renderImportResult(req: Request, tally: ImportTally) async throws -> View {
        let ctx = ImportResultContext(
            currentUser: req.currentUserContext,
            courseID: tally.courseID.uuidString,
            courseCode: tally.courseCode,
            courseName: tally.courseName,
            testSetupsImported: tally.testSetupsImported,
            assignmentsImported: tally.assignmentsImported,
            usersCreated: tally.usersCreated,
            usersMatched: tally.usersMatched,
            submissionsImported: tally.submissionsImported,
            resultsImported: tally.resultsImported
        )
        return try await req.view.render("admin-import-result", ctx)
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

/// Bundle-id → live-DB-id maps built up during the import transaction.
private struct ImportIDMaps {
    let userIDMap: [String: UUID]
    let setupIDMap: [String: String]
}

// MARK: - Transaction tally

/// Mutable counters accumulated inside the import transaction and returned to the caller.
/// Using a local `var` inside the closure and returning it avoids the Swift 6
/// "mutation of captured var in concurrently-executing code" error.
private struct ImportTally: Sendable {
    var courseID: UUID
    var courseCode: String
    var courseName: String
    var usersCreated: Int = 0
    var usersMatched: Int = 0
    var testSetupsImported: Int = 0
    var assignmentsImported: Int = 0
    var submissionsImported: Int = 0
    var resultsImported: Int = 0
}

// MARK: - View context

private struct ImportResultContext: Encodable {
    let currentUser: CurrentUserContext?
    let courseID: String
    let courseCode: String
    let courseName: String
    let testSetupsImported: Int
    let assignmentsImported: Int
    let usersCreated: Int
    let usersMatched: Int
    let submissionsImported: Int
    let resultsImported: Int
}

// MARK: - Import phase helpers (6c–6h)
//
// These are fileprivate free functions rather than methods on `CourseBundleRoutes`
// so the route struct stays under the swiftlint type_body_length limit.

private func importBundledUsers(
    manifest: CourseBundleManifest, db: Database, tally: inout ImportTally
) async throws -> [String: UUID] {
    var userIDMap: [String: UUID] = [:]
    for bundledUser in manifest.users {
        if let existing = try await APIUser.query(on: db)
            .filter(\.$username == bundledUser.username)
            .first()
        {
            guard let existingID = existing.id else {
                throw Abort(.internalServerError, reason: "User '\(bundledUser.username)' missing id")
            }
            userIDMap[bundledUser.bundleID] = existingID
            tally.usersMatched += 1
        } else {
            // Create placeholder — inert until password reset or SSO login.
            let newUser = APIUser(
                username: bundledUser.username,
                passwordHash: "",  // inert placeholder
                role: bundledUser.role,
                authProvider: nil,
                email: bundledUser.email,
                displayName: bundledUser.displayName
            )
            try await newUser.save(on: db)
            guard let newUserID = newUser.id else {
                throw Abort(.internalServerError, reason: "Created user missing id after save")
            }
            userIDMap[bundledUser.bundleID] = newUserID
            tally.usersCreated += 1
        }
    }
    return userIDMap
}

private func importBundledEnrollments(
    manifest: CourseBundleManifest,
    userIDMap: [String: UUID],
    courseID: UUID,
    db: Database
) async throws {
    for bundleID in manifest.enrolledUserBundleIDs {
        guard let uid = userIDMap[bundleID] else { continue }
        // Skip if already enrolled (matched user already in another course).
        let alreadyEnrolled = try await APICourseEnrollment.query(on: db)
            .filter(\.$userID == uid)
            .filter(\.$course.$id == courseID)
            .first()
        if alreadyEnrolled == nil {
            let enrollment = APICourseEnrollment(userID: uid, courseID: courseID)
            try await enrollment.save(on: db)
        }
    }
}

private func importBundledTestSetups(
    manifest: CourseBundleManifest,
    extractDir: URL,
    setupsDir: String,
    courseID: UUID,
    db: Database,
    tally: inout ImportTally
) async throws -> [String: String] {
    var setupIDMap: [String: String] = [:]
    for bundledSetup in manifest.testSetups {
        let newSetupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let newZipPath = setupsDir + "\(newSetupID).zip"

        // Copy zip from bundle into testsetups dir.
        let srcZip = extractDir.appendingPathComponent(bundledSetup.zipFilename)
        try FileManager.default.copyItem(
            at: srcZip,
            to: URL(fileURLWithPath: newZipPath))

        // Extract .ipynb if present (browser-mode setups).
        var notebookPath: String?
        if let nbData = extractNotebookFromZip(zipPath: newZipPath) {
            let nbPath = setupsDir + "\(newSetupID).ipynb"
            try nbData.write(to: URL(fileURLWithPath: nbPath))
            notebookPath = nbPath
        }

        let setup = APITestSetup(
            id: newSetupID,
            manifest: bundledSetup.manifest,
            zipPath: newZipPath,
            notebookPath: notebookPath,
            courseID: courseID
        )
        try await setup.save(on: db)
        setupIDMap[bundledSetup.bundleID] = newSetupID
        tally.testSetupsImported += 1
    }
    return setupIDMap
}

private func importBundledAssignments(
    manifest: CourseBundleManifest,
    setupIDMap: [String: String],
    courseID: UUID,
    db: Database,
    tally: inout ImportTally
) async throws {
    for bundledAssign in manifest.assignments {
        guard let setupID = setupIDMap[bundledAssign.testSetupBundleID] else { continue }
        let newAssign = APIAssignment(
            testSetupID: setupID,
            title: bundledAssign.title,
            slug: try await uniqueAssignmentSlug(title: bundledAssign.title, courseID: courseID, db: db),
            dueAt: bundledAssign.dueAt,
            isOpen: bundledAssign.isOpen,
            sortOrder: bundledAssign.sortOrder,
            validationStatus: nil,  // not imported — requires re-validation
            courseID: courseID
        )
        try await newAssign.save(on: db)
        tally.assignmentsImported += 1
    }
}

private func importBundledSubmissions(
    manifest: CourseBundleManifest,
    extractDir: URL,
    subsDir: String,
    idMaps: ImportIDMaps,
    db: Database,
    tally: inout ImportTally
) async throws -> [String: String] {
    let userIDMap = idMaps.userIDMap
    let setupIDMap = idMaps.setupIDMap
    var subIDMap: [String: String] = [:]
    for bundledSub in manifest.submissions {
        guard let setupID = setupIDMap[bundledSub.testSetupBundleID] else { continue }
        let userID = userIDMap[bundledSub.userBundleID]

        let srcFile = extractDir.appendingPathComponent(bundledSub.submissionFilename)
        let ext = srcFile.pathExtension
        let newSubID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
        let destName = ext.isEmpty ? "\(newSubID).bin" : "\(newSubID).\(ext)"
        let newFilePath = subsDir + destName
        try FileManager.default.copyItem(
            at: srcFile,
            to: URL(fileURLWithPath: newFilePath))

        let sub = APISubmission(
            id: newSubID,
            testSetupID: setupID,
            zipPath: newFilePath,
            attemptNumber: bundledSub.attemptNumber,
            status: "complete",
            filename: bundledSub.filename,
            userID: userID,
            kind: APISubmission.Kind.student
        )
        try await sub.save(on: db)
        subIDMap[bundledSub.bundleID] = newSubID
        tally.submissionsImported += 1
    }
    return subIDMap
}

private func importBundledResults(
    manifest: CourseBundleManifest,
    subIDMap: [String: String],
    db: Database,
    tally: inout ImportTally
) async throws {
    for bundledResult in manifest.results {
        guard let subID = subIDMap[bundledResult.submissionBundleID] else { continue }
        let newResultID = "res_\(UUID().uuidString.lowercased().prefix(8))"
        let result = APIResult(
            id: newResultID,
            submissionID: subID,
            collectionJSON: bundledResult.collectionJSON,
            source: bundledResult.source
        )
        try await result.save(on: db)
        tally.resultsImported += 1
    }
}
