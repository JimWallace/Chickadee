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

import Vapor
import Fluent
import Core
import Foundation

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
              let courseUUID  = UUID(uuidString: courseIDStr),
              let course      = try await APICourse.find(courseUUID, on: req.db)
        else { throw Abort(.notFound, reason: "Course not found") }

        // ── 1. Load all course data ────────────────────────────────────────

        let testSetups   = try await APITestSetup.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .all()

        let assignments  = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseUUID)
            .all()

        let enrollments  = try await APICourseEnrollment.query(on: req.db)
            .filter(\.$course.$id == courseUUID)
            .all()

        let enrolledUserIDs = enrollments.map(\.userID)
        var enrolledUsers: [APIUser] = []
        if !enrolledUserIDs.isEmpty {
            enrolledUsers = try await APIUser.query(on: req.db)
                .filter(\.$id ~~ enrolledUserIDs)
                .all()
        }

        let setupIDs = testSetups.compactMap(\.id)
        var submissions: [APISubmission] = []
        if !setupIDs.isEmpty {
            submissions = try await APISubmission.query(on: req.db)
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
            additionalUsers = try await APIUser.query(on: req.db)
                .filter(\.$id ~~ uniqueIDs)
                .all()
        }
        let allUsers = (enrolledUsers + additionalUsers)
            .reduce(into: [UUID: APIUser]()) { $0[$1.id!] = $1 }
            .values
            .sorted { ($0.username) < ($1.username) }

        let subIDs = submissions.compactMap(\.id)
        var results: [APIResult] = []
        if !subIDs.isEmpty {
            results = try await APIResult.query(on: req.db)
                .filter(\.$submissionID ~~ subIDs)
                .all()
        }

        // ── 2. Assign bundleIDs ────────────────────────────────────────────

        var userBundleIDByUUID:  [UUID:   String] = [:]
        var setupBundleIDByID:   [String: String] = [:]
        var assignBundleIDByID:  [UUID:   String] = [:]
        var subBundleIDByID:     [String: String] = [:]

        for (i, u) in allUsers.enumerated() {
            guard let uid = u.id else { continue }
            userBundleIDByUUID[uid] = "user_\(i + 1)"
        }
        for (i, s) in testSetups.enumerated() {
            guard let sid = s.id else { continue }
            setupBundleIDByID[sid] = "setup_\(i + 1)"
        }
        for (i, a) in assignments.enumerated() {
            guard let aid = a.id else { continue }
            assignBundleIDByID[aid] = "assign_\(i + 1)"
        }
        for (i, s) in submissions.enumerated() {
            guard let sid = s.id else { continue }
            subBundleIDByID[sid] = "sub_\(i + 1)"
        }

        // ── 3. Build manifest ──────────────────────────────────────────────

        let bundledUsers = allUsers.compactMap { u -> BundledUser? in
            guard let uid = u.id, let bid = userBundleIDByUUID[uid] else { return nil }
            return BundledUser(bundleID: bid, username: u.username,
                               displayName: u.displayName, email: u.email,
                               role: u.role)
        }

        let enrolledBundleIDs = enrolledUserIDs.compactMap { userBundleIDByUUID[$0] }

        let bundledSetups = testSetups.compactMap { s -> BundledTestSetup? in
            guard let sid = s.id, let bid = setupBundleIDByID[sid] else { return nil }
            return BundledTestSetup(
                bundleID:    bid,
                originalID:  sid,
                manifest:    s.manifest,
                zipFilename: "testsetups/\(sid).zip"
            )
        }

        let bundledAssignments = assignments.compactMap { a -> BundledAssignment? in
            guard let aid = a.id, let bid = assignBundleIDByID[aid],
                  let setupBid = setupBundleIDByID[a.testSetupID]
            else { return nil }
            return BundledAssignment(
                bundleID:          bid,
                title:             a.title,
                dueAt:             a.dueAt,
                isOpen:            a.isOpen,
                sortOrder:         a.sortOrder,
                testSetupBundleID: setupBid
            )
        }

        let bundledSubmissions = submissions.compactMap { sub -> BundledSubmission? in
            guard let sid = sub.id, let bid = subBundleIDByID[sid],
                  let setupBid = setupBundleIDByID[sub.testSetupID]
            else { return nil }
            let userBid = sub.userID.flatMap { userBundleIDByUUID[$0] } ?? "unknown"
            let onDiskName = URL(fileURLWithPath: sub.zipPath).lastPathComponent
            return BundledSubmission(
                bundleID:           bid,
                userBundleID:       userBid,
                testSetupBundleID:  setupBid,
                attemptNumber:      sub.attemptNumber ?? 1,
                submittedAt:        sub.submittedAt,
                filename:           sub.filename,
                submissionFilename: "submissions/\(onDiskName)"
            )
        }

        let bundledResults = results.compactMap { r -> BundledResult? in
            guard let subBid = subBundleIDByID[r.submissionID] else { return nil }
            return BundledResult(
                submissionBundleID: subBid,
                collectionJSON:     r.collectionJSON,
                source:             r.source ?? "worker",
                receivedAt:         r.receivedAt
            )
        }

        let manifest = CourseBundleManifest(
            exportedAt:           Date(),
            exportedBy:           caller.username,
            chickadeeVersion:     ChickadeeVersion.current,
            course:               BundledCourse(code: course.code, name: course.name),
            users:                bundledUsers,
            enrolledUserBundleIDs: enrolledBundleIDs,
            assignments:          bundledAssignments,
            testSetups:           bundledSetups,
            submissions:          bundledSubmissions,
            results:              bundledResults
        )

        // ── 4. Write staging directory ─────────────────────────────────────

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-export-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: stagingDir)
        }

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
        for setup in testSetups {
            guard let sid = setup.id else { continue }
            let src = URL(fileURLWithPath: setup.zipPath)
            let dst = stagingDir.appendingPathComponent("testsetups/\(sid).zip")
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dst)
            } else {
                req.logger.warning("Export: test setup zip missing at \(src.path), skipping")
            }
        }

        // Copy submission files
        for sub in submissions {
            let src = URL(fileURLWithPath: sub.zipPath)
            let onDiskName = src.lastPathComponent
            let dst = stagingDir.appendingPathComponent("submissions/\(onDiskName)")
            if FileManager.default.fileExists(atPath: src.path) {
                try FileManager.default.copyItem(at: src, to: dst)
            } else {
                req.logger.warning("Export: submission file missing at \(src.path), skipping")
            }
        }

        // ── 5. Create the bundle ZIP ───────────────────────────────────────

        let dateStr = ISO8601DateFormatter().string(from: Date()).prefix(10)
        let safeCourseCode = course.code.replacingOccurrences(of: "/", with: "-")
        let bundleName = "chickadee-bundle-\(safeCourseCode)-\(dateStr).zip"
        let bundleZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleName).path

        defer {
            try? FileManager.default.removeItem(atPath: bundleZipPath)
        }

        try await createZipArchive(sourceDir: stagingDir, outputPath: bundleZipPath)

        // ── 6. Stream the ZIP to the browser ──────────────────────────────

        guard let zipData = try? Data(contentsOf: URL(fileURLWithPath: bundleZipPath)) else {
            throw Abort(.internalServerError, reason: "Failed to read bundle ZIP")
        }

        var headers = HTTPHeaders()
        headers.add(name: .contentType, value: "application/zip")
        headers.add(name: .contentDisposition,
                    value: "attachment; filename=\"\(bundleName)\"")
        headers.add(name: .contentLength, value: "\(zipData.count)")

        return Response(status: .ok, headers: headers, body: .init(data: zipData))
    }

    // MARK: - POST /admin/courses/import

    @Sendable
    func importCourse(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw Abort(.forbidden) }

        // ── 1. Receive the uploaded bundle ────────────────────────────────

        struct BundleUpload: Content {
            let file: ByteBuffer
        }
        let upload = try req.content.decode(BundleUpload.self)
        var buffer = upload.file
        guard let fileBytes = buffer.readBytes(length: buffer.readableBytes) else {
            throw Abort(.badRequest, reason: "Empty bundle upload")
        }

        // ── 2. Save to temp file and extract ─────────────────────────────

        let tmpZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-import-\(UUID().uuidString).zip").path
        let extractDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-import-ex-\(UUID().uuidString)", isDirectory: true)

        defer {
            try? FileManager.default.removeItem(atPath: tmpZipPath)
            try? FileManager.default.removeItem(at: extractDir)
        }

        try Data(fileBytes).write(to: URL(fileURLWithPath: tmpZipPath))
        try await extractZipArchive(zipPath: tmpZipPath, into: extractDir)

        // ── 3. Parse bundle.json ──────────────────────────────────────────

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
            throw Abort(.badRequest,
                        reason: "Unsupported bundle schemaVersion \(manifest.schemaVersion); expected 1")
        }

        // ── 4. Validate all referenced files exist ────────────────────────

        for setup in manifest.testSetups {
            let path = extractDir.appendingPathComponent(setup.zipFilename)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw Abort(.badRequest,
                            reason: "Bundle is missing test setup file: \(setup.zipFilename)")
            }
        }
        for sub in manifest.submissions {
            let path = extractDir.appendingPathComponent(sub.submissionFilename)
            guard FileManager.default.fileExists(atPath: path.path) else {
                throw Abort(.badRequest,
                            reason: "Bundle is missing submission file: \(sub.submissionFilename)")
            }
        }

        // ── 5. Check for course code conflicts ────────────────────────────

        let existingCourse = try await APICourse.query(on: req.db)
            .filter(\.$code == manifest.course.code)
            .first()
        if let existing = existingCourse, !existing.isArchived {
            throw Abort(.conflict,
                        reason: """
                        A course with code "\(manifest.course.code)" already exists and is active. \
                        Archive it first, then re-import.
                        """)
        }

        // ── 6. Collect directories ────────────────────────────────────────

        let setupsDir = req.application.testSetupsDirectory
        let subsDir   = req.application.submissionsDirectory

        // ── 7. Transactional import ───────────────────────────────────────
        // Return a tally from the closure to avoid captured-var mutation warnings
        // (which are errors in Swift 6 strict mode).

        let tally = try await req.db.transaction { (db) -> ImportTally in
            var t = ImportTally(
                courseID:   UUID(),
                courseCode: manifest.course.code,
                courseName: manifest.course.name
            )

            // 7a. Create course
            let newCourse = APICourse(code: manifest.course.code, name: manifest.course.name)
            try await newCourse.save(on: db)
            t.courseID   = newCourse.id!
            t.courseCode = newCourse.code
            t.courseName = newCourse.name

            // 7b. Resolve users → userIDMap[bundleID] = live UUID
            var userIDMap: [String: UUID] = [:]
            for bundledUser in manifest.users {
                if let existing = try await APIUser.query(on: db)
                    .filter(\.$username == bundledUser.username)
                    .first() {
                    userIDMap[bundledUser.bundleID] = existing.id!
                    t.usersMatched += 1
                } else {
                    // Create placeholder — inert until password reset or SSO login.
                    let newUser = APIUser(
                        username:     bundledUser.username,
                        passwordHash: "", // inert placeholder
                        role:         bundledUser.role,
                        authProvider: nil,
                        email:        bundledUser.email,
                        displayName:  bundledUser.displayName
                    )
                    try await newUser.save(on: db)
                    userIDMap[bundledUser.bundleID] = newUser.id!
                    t.usersCreated += 1
                }
            }

            // 7c. Create enrollments for enrolled users
            for bundleID in manifest.enrolledUserBundleIDs {
                guard let uid = userIDMap[bundleID] else { continue }
                // Skip if already enrolled (matched user already in another course).
                let alreadyEnrolled = try await APICourseEnrollment.query(on: db)
                    .filter(\.$userID == uid)
                    .filter(\.$course.$id == t.courseID)
                    .first()
                if alreadyEnrolled == nil {
                    let enrollment = APICourseEnrollment(userID: uid, courseID: t.courseID)
                    try await enrollment.save(on: db)
                }
            }

            // 7d. Create test setups → setupIDMap[bundleID] = new live ID
            var setupIDMap: [String: String] = [:]
            for bundledSetup in manifest.testSetups {
                let newSetupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
                let newZipPath = setupsDir + "\(newSetupID).zip"

                // Copy zip from bundle into testsetups dir.
                let srcZip = extractDir.appendingPathComponent(bundledSetup.zipFilename)
                try FileManager.default.copyItem(at: srcZip,
                                                 to: URL(fileURLWithPath: newZipPath))

                // Extract .ipynb if present (browser-mode setups).
                var notebookPath: String? = nil
                if let nbData = extractNotebookFromZip(zipPath: newZipPath) {
                    let nbPath = setupsDir + "\(newSetupID).ipynb"
                    try nbData.write(to: URL(fileURLWithPath: nbPath))
                    notebookPath = nbPath
                }

                let setup = APITestSetup(
                    id:           newSetupID,
                    manifest:     bundledSetup.manifest,
                    zipPath:      newZipPath,
                    notebookPath: notebookPath,
                    courseID:     t.courseID
                )
                try await setup.save(on: db)
                setupIDMap[bundledSetup.bundleID] = newSetupID
                t.testSetupsImported += 1
            }

            // 7e. Create assignments
            for bundledAssign in manifest.assignments {
                guard let setupID = setupIDMap[bundledAssign.testSetupBundleID] else { continue }
                let newAssign = APIAssignment(
                    testSetupID:      setupID,
                    title:            bundledAssign.title,
                    dueAt:            bundledAssign.dueAt,
                    isOpen:           bundledAssign.isOpen,
                    sortOrder:        bundledAssign.sortOrder,
                    validationStatus: nil, // not imported — requires re-validation
                    courseID:         t.courseID
                )
                try await newAssign.save(on: db)
                t.assignmentsImported += 1
            }

            // 7f. Create submissions → subIDMap[bundleID] = new live ID
            var subIDMap: [String: String] = [:]
            for bundledSub in manifest.submissions {
                guard let setupID = setupIDMap[bundledSub.testSetupBundleID] else { continue }
                let userID = userIDMap[bundledSub.userBundleID]

                let srcFile  = extractDir.appendingPathComponent(bundledSub.submissionFilename)
                let ext      = srcFile.pathExtension
                let newSubID = "sub_\(UUID().uuidString.lowercased().prefix(8))"
                let destName = ext.isEmpty ? "\(newSubID).bin" : "\(newSubID).\(ext)"
                let newFilePath = subsDir + destName
                try FileManager.default.copyItem(at: srcFile,
                                                 to: URL(fileURLWithPath: newFilePath))

                let sub = APISubmission(
                    id:            newSubID,
                    testSetupID:   setupID,
                    zipPath:       newFilePath,
                    attemptNumber: bundledSub.attemptNumber,
                    status:        "complete",
                    filename:      bundledSub.filename,
                    userID:        userID,
                    kind:          APISubmission.Kind.student
                )
                try await sub.save(on: db)
                subIDMap[bundledSub.bundleID] = newSubID
                t.submissionsImported += 1
            }

            // 7g. Create results
            for bundledResult in manifest.results {
                guard let subID = subIDMap[bundledResult.submissionBundleID] else { continue }
                let newResultID = "res_\(UUID().uuidString.lowercased().prefix(8))"
                let result = APIResult(
                    id:             newResultID,
                    submissionID:   subID,
                    collectionJSON: bundledResult.collectionJSON,
                    source:         bundledResult.source
                )
                try await result.save(on: db)
                t.resultsImported += 1
            }

            return t
        }

        // ── 8. Render result page ─────────────────────────────────────────

        let ctx = ImportResultContext(
            currentUser:         req.currentUserContext,
            courseID:            tally.courseID.uuidString,
            courseCode:          tally.courseCode,
            courseName:          tally.courseName,
            testSetupsImported:  tally.testSetupsImported,
            assignmentsImported: tally.assignmentsImported,
            usersCreated:        tally.usersCreated,
            usersMatched:        tally.usersMatched,
            submissionsImported: tally.submissionsImported,
            resultsImported:     tally.resultsImported
        )
        return try await req.view.render("admin-import-result", ctx)
    }
}

// MARK: - Transaction tally

/// Mutable counters accumulated inside the import transaction and returned to the caller.
/// Using a local `var` inside the closure and returning it avoids the Swift 6
/// "mutation of captured var in concurrently-executing code" error.
private struct ImportTally: Sendable {
    var courseID:            UUID
    var courseCode:          String
    var courseName:          String
    var usersCreated:        Int = 0
    var usersMatched:        Int = 0
    var testSetupsImported:  Int = 0
    var assignmentsImported: Int = 0
    var submissionsImported: Int = 0
    var resultsImported:     Int = 0
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
