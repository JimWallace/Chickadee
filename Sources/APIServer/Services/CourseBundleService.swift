// APIServer/Services/CourseBundleService.swift
//
// Course bundle export and import (#2774). `CourseBundleRoutes` checks the
// caller, parses the request and streams the response; this service owns
// everything between. The export pipeline is here; the import transaction
// and its phase helpers are in CourseBundleService+Import.swift.
//
// Bundle format (schemaVersion 1, or 2 when it carries the dataset library):
//   bundle.json              — CourseBundleManifest (ISO8601 dates)
//   testsetups/<id>.zip      — instructor test-setup archives
//   submissions/<id>.<ext>   — student submission files
//   content/<attachmentID>   — content-item hosted file attachments
//   datasets/<sha256>        — course dataset library versions

import Core
import Fluent
import Foundation
import Vapor

enum CourseBundleService {

    /// A finished export: a temporary zip that the caller streams and then
    /// deletes. The zip must outlive the route handler, because the response
    /// body streams after the handler returns.
    struct ExportedBundle: Sendable {
        let zipPath: String
        let downloadName: String
    }

    // MARK: - Export

    /// Builds the bundle zip for one course in the temporary directory.
    static func exportBundle(
        course: APICourse,
        courseID: UUID,
        caller: APIUser,
        app: Application,
        db: any Database,
        logger: Logger
    ) async throws -> ExportedBundle {
        let data = try await loadExportData(courseUUID: courseID, on: db, logger: logger)
        let bundleIDs = assignExportBundleIDs(data: data)
        let library = try await CourseDatasetService.bundledLibrary(courseID: courseID, on: db)
        let manifest = buildExportManifest(
            course: course, caller: caller, data: data, bundleIDs: bundleIDs, library: library)

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
            setup.id.map { (id: $0, zipPath: setup.zipPath, notebookPath: exportableNotebookPath(of: setup)) }
        }
        let submissionPaths = data.submissions.map(\.zipPath)
        // Hosted content-item attachment files: (on-disk src, in-bundle name).
        // Extracted to primitives here so the thread-pool closure captures no
        // Fluent models (#1158).
        let contentFileCopies: [(src: String, bundleName: String)] = data.contentItems.flatMap { item in
            guard let itemID = item.id else { return [(src: String, bundleName: String)]() }
            return item.attachments.map { att in
                (
                    src: ContentAttachmentStore.path(app, itemID: itemID, attachmentID: att.id),
                    bundleName: "content/\(att.id.uuidString)"
                )
            }
        }
        // One file per distinct hash: two versions with the same bytes share it.
        let blobs = AssignmentVersionBlobStore(testSetupsDirectory: app.testSetupsDirectory)
        let datasetFileCopies: [(src: String, bundleName: String)] = try Set(
            library.flatMap(\.versions).map(\.sha256)
        ).sorted().map { hash in (src: try blobs.path(for: hash), bundleName: "datasets/\(hash)") }
        try await runBlocking {
            try writeExportStaging(
                stagingDir: stagingDir,
                manifestData: manifestData,
                setupCopies: setupCopies,
                submissionPaths: submissionPaths,
                contentFileCopies: contentFileCopies,
                logger: logger)
            try writeDatasetStaging(stagingDir: stagingDir, copies: datasetFileCopies)
        }

        let dateStr = iso8601String(Date()).prefix(10)
        let safeCourseCode = course.code.replacingOccurrences(of: "/", with: "-")
        let bundleName = "chickadee-bundle-\(safeCourseCode)-\(dateStr).zip"
        let bundleZipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent(bundleName).path

        // No defer here: the response body streams AFTER the route handler
        // returns, so the temp zip must outlive it. streamTemporaryZip
        // deletes it in the stream's onCompleted hook; the route's catch
        // covers the paths where no stream ever starts.
        try await createZipArchive(sourceDir: stagingDir, outputPath: bundleZipPath)
        return ExportedBundle(zipPath: bundleZipPath, downloadName: bundleName)
    }

    // ── 1. Load all course data ────────────────────────────────────────

    private static func loadExportData(
        courseUUID: UUID, on db: any Database, logger: Logger
    ) async throws -> ExportData {
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
            // Student work AND the instructor's reference solutions. The
            // validation rows are the point of a course copy: an assignment
            // without its solution cannot be re-validated in the new term,
            // because the answer key it would be graded against never
            // travelled. Derived kinds (tournament matches, the class
            // aggregate) are deliberately excluded — they are products of a
            // term's submissions, not content, and they regenerate.
            submissions = try await APISubmission.query(on: db)
                .filter(\.$testSetupID ~~ setupIDs)
                .filter(
                    \.$kind ~~ [APISubmission.Kind.student, APISubmission.Kind.validation]
                )
                .all()
        }
        // A submission whose file is gone from disk stays out of the bundle,
        // with its results. The manifest then names only files the staging
        // copy holds, so the bundle can be imported (#2165).
        submissions = submissions.filter { sub in
            if FileManager.default.fileExists(atPath: sub.zipPath) { return true }
            logger.warning("Export: submission file missing at \(sub.zipPath), left out of the bundle")
            return false
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
        // The runner requirements each assignment declared (#2167).
        let assignmentIDs = assignments.compactMap(\.id)
        var requirementByAssignmentID: [UUID: AssignmentRequirementSpec] = [:]
        if !assignmentIDs.isEmpty {
            for row in try await AssignmentRequirement.query(on: db)
                .filter(\.$assignmentID ~~ assignmentIDs)
                .all()
            {
                requirementByAssignmentID[row.assignmentID] = row.requirementSpec
            }
        }

        return ExportData(
            testSetups: testSetups,
            assignments: assignments,
            sections: sections,
            contentItems: contentItems,
            enrolledUserIDs: enrolledUserIDs,
            enrollments: enrollments,
            allUsers: Array(allUsers),
            submissions: submissions,
            results: results,
            resultCollectionJSONByID: resultCollectionJSONByID,
            requirementByAssignmentID: requirementByAssignmentID
        )
    }

    // ── 2. Assign bundleIDs ────────────────────────────────────────────

    private static func assignExportBundleIDs(data: ExportData) -> ExportBundleIDs {
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

    private static func buildExportManifest(
        course: APICourse,
        caller: APIUser,
        data: ExportData,
        bundleIDs: ExportBundleIDs,
        library: [BundledDataset]
    ) -> CourseBundleManifest {
        let bundledUsers = data.allUsers.compactMap { u -> BundledUser? in
            guard let uid = u.id, let bid = bundleIDs.userBundleIDByUUID[uid] else { return nil }
            return BundledUser(
                bundleID: bid, username: u.username,
                displayName: u.displayName, email: u.email,
                role: u.role)
        }

        let enrolledBundleIDs = data.enrolledUserIDs.compactMap { bundleIDs.userBundleIDByUUID[$0] }
        let bundledEnrollments = data.enrollments.compactMap { e -> BundledEnrollment? in
            guard let bid = bundleIDs.userBundleIDByUUID[e.userID] else { return nil }
            return BundledEnrollment(userBundleID: bid, role: e.role)
        }

        let bundledSetups = data.testSetups.compactMap { s -> BundledTestSetup? in
            guard let sid = s.id, let bid = bundleIDs.setupBundleIDByID[sid] else { return nil }
            return BundledTestSetup(
                bundleID: bid,
                originalID: sid,
                // v1, so a deployment that predates v2 can import the bundle.
                manifest: manifestTextAsV1(s.manifest),
                zipFilename: "testsetups/\(sid).zip",
                notebookFilename: exportableNotebookPath(of: s).map { _ in "testsetups/\(sid).ipynb" }
            )
        }

        let bundledSections = buildBundledSections(data: data, bundleIDs: bundleIDs)
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
                sectionBundleID: a.sectionID.flatMap { bundleIDs.sectionBundleIDByUUID[$0] },
                secretRevealEnabled: a.secretRevealEnabled,
                passingThresholdPercent: a.passingThresholdPercent,
                solutionVisibility: a.solutionVisibility,
                brightspaceSyncExcluded: a.brightspaceSyncExcluded,
                deadlineOverrideActive: a.deadlineOverrideActive,
                requirement: data.requirementByAssignmentID[aid],
                concept: a.concept?.rawValue
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
                submissionFilename: "submissions/\(onDiskName)",
                kind: sub.kind
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

        // Version 2 only for a bundle that carries the library, so one without
        // stays readable by a server that knows only version 1.
        return CourseBundleManifest(
            schemaVersion: library.isEmpty ? 1 : CourseBundleManifest.datasetsSchemaVersion,
            exportedAt: Date(),
            exportedBy: caller.username,
            chickadeeVersion: ChickadeeVersion.current,
            course: bundledCourse(course),
            users: bundledUsers,
            enrolledUserBundleIDs: enrolledBundleIDs,
            enrollments: bundledEnrollments,
            sections: bundledSections,
            contentItems: bundledContentItems,
            assignments: bundledAssignments,
            testSetups: bundledSetups,
            submissions: bundledSubmissions,
            results: bundledResults,
            datasets: library.isEmpty ? nil : library
        )
    }

    /// Maps each course content item to its bundle representation, nesting the
    /// attachment metadata. Each attachment's global UUID doubles as its unique
    /// bundle filename (`content/<id>`); the bytes are copied in
    /// writeExportStaging.
    /// The course row of the manifest: identity, enrollment mode, slip-day
    /// policy, term, and the course's own authoring guide (#1737).
    private static func bundledCourse(_ course: APICourse) -> BundledCourse {
        BundledCourse(
            code: course.code, name: course.name,
            enrollmentMode: course.enrollmentMode,
            slipDaysEnabled: course.slipDaysEnabled,
            slipDaysPerStudent: course.slipDaysPerStudent,
            slipDayExtensionHours: course.slipDayExtensionHours,
            slipDayReleaseRevealHold: course.slipDayReleaseRevealHold,
            term: course.term,
            mcpInstructions: course.mcpInstructions)
    }

    private static func buildBundledSections(data: ExportData, bundleIDs: ExportBundleIDs) -> [BundledSection] {
        data.sections.compactMap { sec -> BundledSection? in
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
    }

    private static func buildBundledContentItems(
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
}

// ── 4. Write staging directory ─────────────────────────────────────
//
// Free function over primitives so the export handler can run it on the
// thread pool without capturing non-Sendable Fluent models (#1158).
private func writeExportStaging(
    stagingDir: URL,
    manifestData: Data,
    setupCopies: [(id: String, zipPath: String, notebookPath: String?)],
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
        // A setup zip is the assignment's content. Without it the bundle
        // would name a file it does not hold and the import would refuse
        // it, so the export fails here and names the setup (#2165). The
        // message shows no server path.
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw AppError.internalFailure(
                reason: "The course cannot be exported: test setup \(setup.id) has no zip file.")
        }
        try FileManager.default.copyItem(at: src, to: dst)
        // The starter notebook as it is now, beside the zip (#1736).
        if let notebookPath = setup.notebookPath {
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: notebookPath),
                to: stagingDir.appendingPathComponent("testsetups/\(setup.id).ipynb"))
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

/// Copies the dataset library's version files into `datasets/`. A version is
/// library content, as a setup zip is: without its bytes the import would
/// refuse the bundle, so a missing blob fails the export and names it.
private func writeDatasetStaging(stagingDir: URL, copies: [(src: String, bundleName: String)]) throws {
    guard !copies.isEmpty else { return }
    try FileManager.default.createDirectory(
        at: stagingDir.appendingPathComponent("datasets"), withIntermediateDirectories: true)
    for copy in copies {
        guard FileManager.default.fileExists(atPath: copy.src) else {
            throw AppError.internalFailure(
                reason: "Export: the bytes of dataset version \(copy.bundleName) are missing")
        }
        try FileManager.default.copyItem(
            at: URL(fileURLWithPath: copy.src), to: stagingDir.appendingPathComponent(copy.bundleName))
    }
}

/// The setup's starter notebook path when the file exists on disk, so the
/// manifest names only files the staging copy will hold.
private func exportableNotebookPath(of setup: APITestSetup) -> String? {
    guard let path = setup.notebookPath, FileManager.default.fileExists(atPath: path) else { return nil }
    return path
}

// MARK: - Export data carriers

/// All the data fetched from the database for an export.
private struct ExportData {
    let testSetups: [APITestSetup]
    let assignments: [APIAssignment]
    let sections: [APICourseSection]
    let contentItems: [APICourseContentItem]
    let enrolledUserIDs: [UUID]
    let enrollments: [APICourseEnrollment]
    let allUsers: [APIUser]
    let submissions: [APISubmission]
    let results: [APIResult]
    /// Collection blob per result id, batch-fetched from the side table.
    let resultCollectionJSONByID: [String: String]
    let requirementByAssignmentID: [UUID: AssignmentRequirementSpec]
}

/// Maps from live DB ids to in-bundle synthetic identifiers used for cross-references.
private struct ExportBundleIDs {
    let userBundleIDByUUID: [UUID: String]
    let setupBundleIDByID: [String: String]
    let assignBundleIDByID: [UUID: String]
    let subBundleIDByID: [String: String]
    let sectionBundleIDByUUID: [UUID: String]
}
