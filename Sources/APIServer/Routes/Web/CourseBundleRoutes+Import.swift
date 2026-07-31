// APIServer/Routes/Web/CourseBundleRoutes+Import.swift
//
// Course bundle import: the POST /admin/courses/import handler and its
// phase helpers.  Split from CourseBundleRoutes.swift (which keeps boot +
// export) — no behaviour changes.
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

extension CourseBundleRoutes {

    // MARK: - POST /admin/courses/import

    @Sendable
    func importCourse(req: Request) async throws -> View {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isAdmin else { throw Abort(.forbidden) }

        let uploadBuffer = try readUploadedBundleBuffer(req: req)

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

        let manifest = try parseBundleManifest(extractDir: extractDir)

        try validateBundleFiles(manifest: manifest, extractDir: extractDir)

        let setupsDir = req.application.testSetupsDirectory
        let subsDir = req.application.submissionsDirectory
        let contentFilesDir = req.application.contentFilesDirectory

        let tally = try await performImportTransaction(
            db: req.db,
            manifest: manifest,
            extractDir: extractDir,
            setupsDir: setupsDir,
            subsDir: subsDir,
            contentFilesDir: contentFilesDir
        )

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

    // ── 1. Receive the uploaded bundle ────────────────────────────────

    private func readUploadedBundleBuffer(req: Request) throws -> ByteBuffer {
        struct BundleUpload: Content {
            let file: File
        }
        let upload = try req.content.decode(BundleUpload.self)
        guard upload.file.data.readableBytes > 0 else {
            throw AppError.badRequest(reason: "Empty bundle upload")
        }
        // The ByteBuffer goes straight to fileio — the old
        // ByteBuffer → [UInt8] → Data chain held three full copies of a
        // potentially multi-hundred-MB bundle in heap at once (#1158).
        return upload.file.data
    }

    // ── 2. Save to temp file and extract ─────────────────────────────

    private func extractUploadedBundle(
        req: Request, buffer: ByteBuffer, tmpZipPath: String, extractDir: URL
    ) async throws {
        try await req.fileio.writeFile(buffer, at: tmpZipPath)
        try await extractZipArchive(zipPath: tmpZipPath, into: extractDir)
    }

    // ── 3. Parse bundle.json ──────────────────────────────────────────

    private func parseBundleManifest(extractDir: URL) throws -> CourseBundleManifest {
        let bundleJSONPath = extractDir.appendingPathComponent("bundle.json")
        guard let manifestData = try? Data(contentsOf: bundleJSONPath) else {
            throw AppError.badRequest(reason: "bundle.json not found in archive")
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let manifest: CourseBundleManifest
        do {
            manifest = try decoder.decode(CourseBundleManifest.self, from: manifestData)
        } catch {
            throw AppError.invalidParameter(name: "bundle.json", reason: "\(error)")
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
        for item in manifest.contentItems ?? [] {
            for att in item.attachments ?? [] {
                guard
                    let path = safeContentAttachmentSource(
                        extractDir: extractDir, bundleFilename: att.bundleFilename),
                    FileManager.default.fileExists(atPath: path.path)
                else {
                    throw Abort(
                        .badRequest,
                        reason:
                            "Bundle is missing or has an invalid content attachment file: "
                            + att.bundleFilename)
                }
            }
        }
    }

    /// Resolves an attachment's in-bundle path to a safe source under the
    /// extract dir: only `content/<uuid>` is accepted (its last component must be
    /// a UUID), so a hostile `bundleFilename` can't traverse out of the extract
    /// dir. Returns nil for anything else.
    private func safeContentAttachmentSource(extractDir: URL, bundleFilename: String) -> URL? {
        let name = (bundleFilename as NSString).lastPathComponent
        guard UUID(uuidString: name) != nil else { return nil }
        return extractDir.appendingPathComponent("content").appendingPathComponent(name)
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
        subsDir: String,
        contentFilesDir: String
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
            // Slip-day policy travels with the course (#1228); the ledger and
            // per-student adjustments deliberately do not (per-term data).
            let slipDayPolicy = bundledCourseSlipDayPolicy(manifest.course)
            newCourse.slipDaysEnabled = slipDayPolicy.enabled
            newCourse.slipDaysPerStudent = slipDayPolicy.daysPerStudent
            newCourse.slipDayExtensionHours = slipDayPolicy.extensionHours
            try await newCourse.save(on: db)
            guard let newCourseID = newCourse.id else {
                throw AppError.internalFailure(reason: "Created course missing id after save")
            }
            t.courseID = newCourseID
            t.courseCode = newCourse.code
            t.courseName = newCourse.name

            // 6c. Resolve users → userIDMap[bundleID] = live UUID
            let userIDMap = try await importBundledUsers(manifest: manifest, db: db, tally: &t)

            // 6d. Create enrollments for enrolled users
            try await importBundledEnrollments(
                manifest: manifest, userIDMap: userIDMap, courseID: t.courseID, db: db)

            // 6e. Create course sections → sectionIDMap[bundleID] = new live UUID
            let sectionIDMap = try await importBundledSections(
                manifest: manifest, courseID: t.courseID, db: db)

            // 6e-bis. Create ungraded content items, re-linked to the sections
            // recreated above (depends only on sectionIDMap).
            try await importBundledContentItems(
                manifest: manifest, sectionIDMap: sectionIDMap, courseID: t.courseID,
                extractDir: extractDir, contentFilesDir: contentFilesDir, db: db)

            // 6f. Create test setups → setupIDMap[bundleID] = new live ID
            let setupIDMap = try await importBundledTestSetups(
                manifest: manifest, extractDir: extractDir, setupsDir: setupsDir,
                courseID: t.courseID, db: db, tally: &t)

            // 6g. Create assignments
            try await importBundledAssignments(
                manifest: manifest, setupIDMap: setupIDMap, sectionIDMap: sectionIDMap,
                courseID: t.courseID, db: db, tally: &t)

            // 6h. Create submissions → subIDMap[bundleID] = new live ID
            let subIDMap = try await importBundledSubmissions(
                manifest: manifest, extractDir: extractDir, subsDir: subsDir,
                idMaps: ImportIDMaps(userIDMap: userIDMap, setupIDMap: setupIDMap),
                db: db, tally: &t)

            // 6i. Create results
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

// MARK: - Import data carriers

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
                throw AppError.internalFailure(reason: "User '\(bundledUser.username)' missing id")
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
                throw AppError.internalFailure(reason: "Created user missing id after save")
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
            try await saveSeededEnrollment(userID: uid, courseID: courseID, on: db)
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

/// Recreates the bundle's course sections in the new course. Returns a map
/// from in-bundle section bundleID to the new live UUID, used to re-link
/// assignments. Bundles exported before sections were carried have no
/// `sections` array and yield an empty map (assignments land ungrouped).
private func importBundledSections(
    manifest: CourseBundleManifest,
    courseID: UUID,
    db: Database
) async throws -> [String: UUID] {
    var sectionIDMap: [String: UUID] = [:]
    for bundledSection in manifest.sections ?? [] {
        let newSection = APICourseSection(
            name: bundledSection.name,
            defaultGradingMode: bundledSection.defaultGradingMode,
            sortOrder: bundledSection.sortOrder,
            courseID: courseID
        )
        try await newSection.save(on: db)
        sectionIDMap[bundledSection.bundleID] = try newSection.requireID()
    }
    return sectionIDMap
}

/// Recreates the bundle's ungraded content items in the new course, re-linking
/// each to its recreated section via `sectionIDMap` (a `sectionBundleID` with no
/// mapping — including nil — lands the item ungrouped). Bundles exported before
/// content items were carried have no `contentItems` array and import nothing.
private func importBundledContentItems(
    manifest: CourseBundleManifest,
    sectionIDMap: [String: UUID],
    courseID: UUID,
    extractDir: URL,
    contentFilesDir: String,
    db: Database
) async throws {
    for item in manifest.contentItems ?? [] {
        let newItem = APICourseContentItem(
            courseID: courseID,
            sectionID: item.sectionBundleID.flatMap { sectionIDMap[$0] },
            sortOrder: item.sortOrder,
            title: item.title,
            kind: ContentItemKind(rawValue: item.kind) ?? .link,
            itemDescription: item.description,
            links: item.links,
            updatedLabel: item.updatedLabel,
            isPublished: item.isPublished
        )
        try await newItem.save(on: db)

        // Re-host each attachment under freshly generated ids: copy the bundle
        // file (content/<uuid>, validated safe) into the new item's directory.
        guard let newItemID = newItem.id, let bundleAtts = item.attachments, !bundleAtts.isEmpty
        else { continue }
        let destDir = contentFilesDir + newItemID.uuidString + "/"
        try FileManager.default.createDirectory(atPath: destDir, withIntermediateDirectories: true)
        var stored: [ContentAttachment] = []
        for att in bundleAtts {
            let name = (att.bundleFilename as NSString).lastPathComponent
            guard UUID(uuidString: name) != nil else { continue }
            let src = extractDir.appendingPathComponent("content").appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let newAttachmentID = UUID()
            try FileManager.default.copyItem(
                atPath: src.path, toPath: destDir + newAttachmentID.uuidString)
            stored.append(
                ContentAttachment(
                    id: newAttachmentID,
                    originalName: FilenameSafety.bareFilename(att.originalName) ?? "attachment",
                    sizeBytes: att.sizeBytes,
                    sortOrder: att.sortOrder,
                    label: att.label))
        }
        if !stored.isEmpty {
            newItem.attachments = stored
            try await newItem.save(on: db)
        }
    }
}

private func importBundledAssignments(
    manifest: CourseBundleManifest,
    setupIDMap: [String: String],
    sectionIDMap: [String: UUID],
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
            startsAt: bundledAssign.startsAt,
            visibility: bundledAssignmentVisibility(bundledAssign),
            sortOrder: bundledAssign.sortOrder,
            validationStatus: nil,  // not imported — requires re-validation
            sectionID: bundledAssign.sectionBundleID.flatMap { sectionIDMap[$0] },
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
            status: SubmissionStatus.complete.rawValue,
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
            source: bundledResult.source
        )
        try await result.saveWithCollection(json: bundledResult.collectionJSON, on: db)
        tally.resultsImported += 1
    }
}
