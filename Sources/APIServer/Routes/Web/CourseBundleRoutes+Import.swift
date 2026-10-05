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
//   - Term: the bundle's year and term, if it carries one; else no term
//     (the result page asks the admin to set it — docs/course-terms.md)
//   - Users: match by username or create placeholder (inert until password reset)
//   - All DB IDs are regenerated; bundleIDs are internal cross-references only.
//   - validationStatus is NOT imported; assignments land as "pending" validation.
//     The reference SOLUTION does travel, as a "validation"-kind submission,
//     and each imported assignment is re-linked to its own copy — so a
//     "pending" assignment is one that CAN be re-validated, which before was
//     not true of any imported assignment.

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
        try validateBundleKinds(manifest: manifest)

        let setupsDir = req.application.testSetupsDirectory
        let subsDir = req.application.submissionsDirectory
        let contentFilesDir = req.application.contentFilesDirectory

        let tally = try await performImportTransaction(
            app: req.application,
            db: req.db,
            manifest: manifest,
            dirs: BundleImportDirectories(
                extractDir: extractDir, setupsDir: setupsDir,
                subsDir: subsDir, contentFilesDir: contentFilesDir)
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

    // ── 4b. Validate the enum-valued fields ───────────────────────────

    /// A bundle from a newer server can name a content item kind or a
    /// section grading mode this server does not know. The import refuses
    /// it here and names the item, instead of importing the item as a link
    /// in silence (#2172).
    private func validateBundleKinds(manifest: CourseBundleManifest) throws {
        for item in manifest.contentItems ?? [] {
            _ = try bundledContentItemKind(item)
        }
        for section in manifest.sections ?? [] {
            _ = try bundledSectionGradingMode(section)
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

    func performImportTransaction(
        app: Application,
        db: Database,
        manifest: CourseBundleManifest,
        dirs: BundleImportDirectories
    ) async throws -> ImportTally {
        let extractDir = dirs.extractDir
        let subsDir = dirs.subsDir
        return try await db.transaction { (db) -> ImportTally in
            // 6a. Check for course code conflicts (moved inside transaction)
            // Asks for an ACTIVE match: a first-match query could return an
            // archived duplicate, pass, and then fail on the unique index.
            if try await activeCourseCodeIsTaken(
                manifest.course.code, term: bundledCourseTerm(manifest.course), excluding: nil, on: db)
            {
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
            do {
                // 6b. Create course
                let importedMode = bundledCourseEnrollmentMode(manifest.course)
                let newCourse = APICourse(
                    code: manifest.course.code, name: manifest.course.name,
                    enrollmentMode: importedMode,
                    term: bundledCourseTerm(manifest.course))
                // Slip-day policy travels with the course (#1228); the ledger and
                // per-student adjustments deliberately do not (per-term data).
                let slipDayPolicy = bundledCourseSlipDayPolicy(manifest.course)
                newCourse.slipDaysEnabled = slipDayPolicy.enabled
                newCourse.slipDaysPerStudent = slipDayPolicy.daysPerStudent
                newCourse.slipDayExtensionHours = slipDayPolicy.extensionHours
                newCourse.slipDayReleaseRevealHold = slipDayPolicy.releaseRevealHold
                // The course's own authoring guide, when it has one (#1737).
                newCourse.mcpInstructions = manifest.course.mcpInstructions
                try await newCourse.save(on: db)
                guard let newCourseID = newCourse.id else {
                    throw AppError.internalFailure(reason: "Created course missing id after save")
                }
                t.courseID = newCourseID
                t.courseCode = newCourse.code
                t.courseName = newCourse.name
                t.termLabel = newCourse.term?.displayName

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
                    dirs: dirs, db: db, tally: &t)

                // 6f. Create test setups → setupIDMap[bundleID] = new live ID
                let setupIDMap = try await importBundledTestSetups(
                    manifest: manifest, dirs: dirs, courseID: t.courseID,
                    app: app, db: db, tally: &t)

                // 6g. Create assignments
                try await importBundledAssignments(
                    manifest: manifest, setupIDMap: setupIDMap, sectionIDMap: sectionIDMap,
                    courseID: t.courseID, db: db, tally: &t)

                // 6h. Create submissions → subIDMap[bundleID] = new live ID
                let subIDMap = try await importBundledSubmissions(
                    manifest: manifest, extractDir: extractDir, subsDir: subsDir,
                    idMaps: ImportIDMaps(userIDMap: userIDMap, setupIDMap: setupIDMap),
                    db: db, tally: &t)

                // 6h-bis. Point each imported assignment at its own imported
                // reference solution. The submissions above landed on the NEW
                // setup ids, so this is what turns a carried solution into one the
                // assignment can actually resolve.
                try await linkImportedValidationSubmissions(
                    courseID: t.courseID, setupsDir: dirs.setupsDir, db: db)

                // 6h-ter. Seed each imported assignment's v1, as clone and create
                // do, so it has a starting point to roll back to and the timeline
                // can say it arrived by import (#1741). After 6g and 6h-bis: the
                // version store records only a published assignment, and the
                // snapshot should see the linked solution.
                await seedImportedVersions(setupIDs: setupIDMap.values, setupsDir: dirs.setupsDir, db: db)

                // 6i. Create results
                try await importBundledResults(
                    manifest: manifest, subIDMap: subIDMap, db: db, tally: &t)

                return t
            } catch {
                // The rows roll back with the transaction; the files the
                // import wrote would stay. Remove them before the error
                // leaves, as the course clone does (#1743, #2164).
                let fm = FileManager.default
                for path in t.createdPaths { try? fm.removeItem(atPath: path) }
                throw error
            }
        }
    }

    // ── 8. Render result page ─────────────────────────────────────────

    private func renderImportResult(req: Request, tally: ImportTally) async throws -> View {
        let ctx = ImportResultContext(
            currentUser: req.currentUserContext,
            courseID: tally.courseID.uuidString,
            courseCode: tally.courseCode,
            courseName: tally.courseName,
            termLabel: tally.termLabel,
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
struct ImportTally: Sendable {
    var courseID: UUID
    var courseCode: String
    var courseName: String
    var termLabel: String?
    var usersCreated: Int = 0
    var usersMatched: Int = 0
    var testSetupsImported: Int = 0
    var assignmentsImported: Int = 0
    var submissionsImported: Int = 0
    var resultsImported: Int = 0
    /// Every file and directory the import wrote, recorded before the
    /// write, so a failed transaction can remove them (#2164).
    var createdPaths: [String] = []
}

// MARK: - View context

private struct ImportResultContext: Encodable {
    let currentUser: CurrentUserContext?
    let courseID: String
    let courseCode: String
    let courseName: String
    /// "Fall 2026", or nil when the bundle carried no term.
    let termLabel: String?
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
                // A bundle from before the per-course roles (#417) says
                // `student` or `instructor` here; both are plain users now.
                role: (UserRole(rawValue: bundledUser.role) ?? .user).rawValue,
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
    // A bundle that carries roles (#1740) enrolls each user in the role it
    // held. An older bundle lists only who was enrolled, and the seeded
    // enrollment decides the role as it always has.
    let entries: [(bundleID: String, role: CourseRole?)]
    if let enrollments = manifest.enrollments {
        entries = enrollments.map { ($0.userBundleID, $0.role) }
    } else {
        entries = manifest.enrolledUserBundleIDs.map { ($0, nil) }
    }
    for entry in entries {
        guard let uid = userIDMap[entry.bundleID] else { continue }
        // Skip if already enrolled (matched user already in another course).
        let alreadyEnrolled = try await APICourseEnrollment.query(on: db)
            .filter(\.$userID == uid)
            .filter(\.$course.$id == courseID)
            .first()
        if alreadyEnrolled == nil {
            if let role = entry.role {
                try await APICourseEnrollment(userID: uid, courseID: courseID, role: role).save(on: db)
            } else {
                try await saveSeededEnrollment(userID: uid, courseID: courseID, on: db)
            }
        }
    }
}

/// The filesystem destinations a bundle import writes into, bundled so the
/// import helpers stay within the parameter-count limit.
struct BundleImportDirectories: Sendable {
    let extractDir: URL
    let setupsDir: String
    let subsDir: String
    let contentFilesDir: String
}

private func importBundledTestSetups(
    manifest: CourseBundleManifest,
    dirs: BundleImportDirectories,
    courseID: UUID,
    app: Application,
    db: Database,
    tally: inout ImportTally
) async throws -> [String: String] {
    let extractDir = dirs.extractDir
    let setupsDir = dirs.setupsDir
    var setupIDMap: [String: String] = [:]
    for bundledSetup in manifest.testSetups {
        let newSetupID = freshShortID(prefix: "setup")
        let newZipPath = setupsDir + "\(newSetupID).zip"

        // Copy zip from bundle into testsetups dir — a whole test setup
        // archive per loop turn, on the thread pool rather than the
        // cooperative pool (#1382 item 9; app-scoped because this runs
        // inside the import transaction, whose closure cannot capture the
        // request).
        let srcZip = extractDir.appendingPathComponent(bundledSetup.zipFilename)
        tally.createdPaths.append(newZipPath)
        try await runBlocking(app: app) {
            try FileManager.default.copyItem(
                at: srcZip,
                to: URL(fileURLWithPath: newZipPath))
        }

        // The starter notebook: the flat file the bundle carries (#1736), else
        // the zip entry an older bundle may hold (browser-mode setups).
        var notebookPath: String?
        if let bundledNotebook = bundledSetup.notebookFilename,
            FileManager.default.fileExists(atPath: extractDir.appendingPathComponent(bundledNotebook).path)
        {
            let nbPath = setupsDir + "\(newSetupID).ipynb"
            tally.createdPaths.append(nbPath)
            try await runBlocking(app: app) {
                try FileManager.default.copyItem(
                    at: extractDir.appendingPathComponent(bundledNotebook), to: URL(fileURLWithPath: nbPath))
            }
            notebookPath = nbPath
        } else if let nbData = await extractNotebookFromZip(zipPath: newZipPath) {
            let nbPath = setupsDir + "\(newSetupID).ipynb"
            tally.createdPaths.append(nbPath)
            try await runBlocking(app: app) {
                try nbData.write(to: URL(fileURLWithPath: nbPath))
            }
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
        // The zip copy above carries the support files, but students and
        // personalization expressions read them from the shared directory.
        tally.createdPaths.append(setupsDir + "shared/\(newSetupID)/")
        await extractSupportFilesToSharedDirectory(for: setup, testSetupsDirectory: setupsDir)
        // A bundle exported by an older build carries no language declaration,
        // so declare one on the way in — the same thing
        // `BackfillDeclaredLanguage` does for content already on disk, applied
        // at the one other door assignments come through.
        //
        // Without this, import is a permanent source of undeclared assignments,
        // and "undeclared" is exactly the state the worker must be able to
        // refuse rather than guess at. A refusal that legitimate imports can
        // trip is a refusal that has to be watered down.
        //
        // The notebook is already on disk above, so resolution can consult its
        // kernel; an assignment nothing identifies is declared as having no
        // language, which is the truthful answer for a shell-script suite.
        if let imported = setup.decodedManifest(), imported.languageDeclared != true {
            try await declareManifestLanguage(
                setup: setup,
                to: AssignmentLanguage.derivedDeclaration(
                    manifest: imported,
                    notebookData: setup.notebookPath.flatMap { FileManager.default.contents(atPath: $0) }),
                on: db)
        }

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
            defaultGradingMode: try bundledSectionGradingMode(bundledSection).rawValue,
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
    dirs: BundleImportDirectories,
    db: Database,
    tally: inout ImportTally
) async throws {
    let extractDir = dirs.extractDir
    let contentFilesDir = dirs.contentFilesDir
    for item in manifest.contentItems ?? [] {
        let newItem = APICourseContentItem(
            courseID: courseID,
            sectionID: item.sectionBundleID.flatMap { sectionIDMap[$0] },
            sortOrder: item.sortOrder,
            title: item.title,
            kind: try bundledContentItemKind(item),
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
        tally.createdPaths.append(destDir)
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
        // The four per-assignment policies (#1737). A bundle written before
        // they were carried leaves each at its column default.
        newAssign.secretRevealEnabled = bundledAssign.secretRevealEnabled
        newAssign.passingThresholdPercent = bundledAssign.passingThresholdPercent
        if let solutionVisibility = bundledAssign.solutionVisibility {
            newAssign.solutionVisibility = solutionVisibility
        }
        newAssign.brightspaceSyncExcluded = bundledAssign.brightspaceSyncExcluded
        // The deadline override travels with the open state it protects
        // (#2166): without it the next sweep closes an imported assignment
        // whose due date has passed.
        if let deadlineOverrideActive = bundledAssign.deadlineOverrideActive {
            newAssign.deadlineOverrideActive = deadlineOverrideActive
        }
        try await newAssign.save(on: db)
        tally.assignmentsImported += 1
    }
}

/// Seeds `v1` for every imported setup. Best effort, like the other seeds:
/// an assignment with no history is what the store already copes with.
private func seedImportedVersions(setupIDs: some Sequence<String>, setupsDir: String, db: Database) async {
    for setupID in setupIDs {
        guard let setup = try? await APITestSetup.find(setupID, on: db) else { continue }
        await AssignmentVersionStore.seedInitialVersion(
            setup: setup, origin: AssignmentVersionOrigin.bundleImport,
            testSetupsDirectory: setupsDir, on: db)
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
        let copied = try copySubmissionFile(from: srcFile.path, into: subsDir)
        tally.createdPaths.append(copied.path)

        let sub = APISubmission(
            id: copied.id,
            testSetupID: setupID,
            zipPath: copied.path,
            attemptNumber: bundledSub.attemptNumber,
            status: SubmissionStatus.complete.rawValue,
            filename: bundledSub.filename,
            userID: userID,
            kind: bundledSub.kindOrStudent
        )
        try await sub.save(on: db)
        // The create stamp is import time; the bundle carries when the
        // student submitted, and the history page and the solution ordering
        // read that (#1739).
        if let submittedAt = bundledSub.submittedAt {
            sub.submittedAt = submittedAt
            try await sub.save(on: db)
        }
        subIDMap[bundledSub.bundleID] = copied.id
        tally.submissionsImported += 1
    }
    return subIDMap
}

/// Sets `validationSubmissionID` on every assignment in the freshly imported
/// course that has a reference solution among the imported submissions.
///
/// Resolution would find it anyway — `MCPStudentDataBoundary` falls back to the
/// newest validation submission for the assignment's setup — but the stored
/// pointer is what the authoring pages read to decide an assignment HAS a
/// solution, so leaving it nil shows an imported assignment as having none.
/// Also writes each linked solution's source into the setup's shared
/// directory, which the import built from the zip alone (#1742).
private func linkImportedValidationSubmissions(
    courseID: UUID,
    setupsDir: String,
    db: Database
) async throws {
    let assignments = try await APIAssignment.query(on: db)
        .filter(\.$courseID == courseID)
        .all()
    for assignment in assignments {
        guard
            let solution = try await APISubmission.query(on: db)
                .filter(\.$testSetupID == assignment.testSetupID)
                .filter(\.$kind == APISubmission.Kind.validation)
                .sort(\.$submittedAt, .descending)
                .first(),
            let solutionID = solution.id
        else { continue }
        assignment.validationSubmissionID = solutionID
        try await assignment.save(on: db)
        if let setup = try await APITestSetup.find(assignment.testSetupID, on: db) {
            await SolutionNotebookExtractor.writeSolutionSource(
                fromCopiedSolution: solution, setup: setup, testSetupsDirectory: setupsDir)
        }
    }
}

private func importBundledResults(
    manifest: CourseBundleManifest,
    subIDMap: [String: String],
    db: Database,
    tally: inout ImportTally
) async throws {
    for bundledResult in manifest.results {
        guard let subID = subIDMap[bundledResult.submissionBundleID] else { continue }
        let newResultID = freshShortID(prefix: "res")
        let result = APIResult(
            id: newResultID,
            submissionID: subID,
            source: bundledResult.source
        )
        try await result.saveWithCollection(json: bundledResult.collectionJSON, on: db)
        if let receivedAt = bundledResult.receivedAt {
            result.receivedAt = receivedAt
            try await result.save(on: db)
        }
        tally.resultsImported += 1
    }
}

/// The content item kind a bundled item names, or a `badRequest` that names
/// the item and the kind (#2172).
private func bundledContentItemKind(_ item: BundledContentItem) throws -> ContentItemKind {
    guard let kind = ContentItemKind(rawValue: item.kind) else {
        throw Abort(
            .badRequest,
            reason: "Bundle content item \"\(item.title)\" has an unknown kind: \(item.kind)")
    }
    return kind
}

/// The grading mode a bundled section names, or a `badRequest` that names
/// the section and the mode (#2172).
private func bundledSectionGradingMode(_ section: BundledSection) throws -> GradingMode {
    guard let mode = GradingMode(rawValue: section.defaultGradingMode) else {
        throw Abort(
            .badRequest,
            reason: "Bundle section \"\(section.name)\" has an unknown grading mode: \(section.defaultGradingMode)")
    }
    return mode
}
