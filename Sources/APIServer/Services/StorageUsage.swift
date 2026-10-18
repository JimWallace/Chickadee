// APIServer/Services/StorageUsage.swift
//
// The storage breakdown that the `/admin/storage` page and the
// admin-diagnostics MCP tool `get_storage_usage` both show. Moved out of
// Routes/Web/AdminRoutes.swift (#2496), so the MCP tool does not depend on the
// web route layer.

import Core
import Fluent
import Foundation
import SQLKit
import Vapor

enum StorageUsage {

    /// Measures the persistent-volume sinks (submission/test-setup uploads,
    /// the results+logs dir, the static asset tree) and the database so an
    /// admin can see where disk is going.
    ///
    /// The admin diagnostic MCP tool (`get_storage_usage`) uses the exact same
    /// builder as the `/admin/storage` page — the context is PII-free
    /// (assignment/course identifiers + byte counts only).
    ///
    /// Cached behind a single-flight TTL (#1382 item 5): the walks stat every
    /// submission ever kept plus the whole static asset tree, so the page got
    /// slowest exactly when there was the most disk to account for — and the
    /// MCP tool made it pollable. The walks now run at most once per TTL.
    static func context(app: Application) async throws -> AdminStorageContext {
        var context = try await app.storageUsageCache.context {
            try await computeStorageContext(app: app)
        }
        // Live, not cached: free space is what an admin opens this page to see
        // when the disk is filling.
        context.disk = app.diskSpaceOfDataVolume
        return context
    }

    /// The uncached breakdown build. Directory walks are blocking, so they
    /// run on the thread pool off the event loop.
    private static func computeStorageContext(app: Application) async throws -> AdminStorageContext {
        let submissionsDir = app.submissionsDirectory
        let testSetupsDir = app.testSetupsDirectory
        let resultsDir = app.resultsDirectory
        let publicDir = app.directory.publicDirectory

        func dirSize(_ path: String) async throws -> Int {
            try await runBlocking { directorySizeBytes(at: path) }
        }

        // Per-id footprints feed both the aggregate cards and the per-assignment
        // breakdown.  Submissions are stored flat (`<id>.<ext>`), so the
        // top-level sum equals a full recursive walk — we reuse it for the
        // "Submissions" card to avoid scanning that (potentially large) dir
        // twice.  Test setups have `shared/`+`notebooks/` subtrees, so the
        // card keeps an authoritative recursive walk.
        async let submissionSizesFetch = runBlocking {
            topLevelFileSizesByID(inDirectory: submissionsDir)
        }
        async let setupSizesFetch = runBlocking {
            testSetupSizesByID(testSetupsDirectory: testSetupsDir)
        }

        async let testSetupsBytes = dirSize(testSetupsDir)
        async let resultsBytes = dirSize(resultsDir)
        async let publicBytes = dirSize(publicDir)
        async let dbBytes = databaseSizeBytes(
            on: app.db, settings: app.appConfig.database)

        // Mapping rows for the per-assignment breakdown.  The (id → setup)
        // projection is the minimal query byte attribution needs: sizes live
        // only on disk, keyed by submission id, so each on-disk file's bytes
        // can only reach its assignment through this map.
        async let assignmentsFetch = APIAssignment.query(on: app.db).all()
        async let coursesFetch = APICourse.query(on: app.db).all()
        async let submissionLinksFetch = APISubmission.query(on: app.db)
            .field(\.$id).field(\.$testSetupID).all()

        let submissionSizesByID = try await submissionSizesFetch
        let setupSizesByID = try await setupSizesFetch
        let testSetups = try await testSetupsBytes
        let results = try await resultsBytes
        let publicAssets = try await publicBytes
        let database = await dbBytes
        let submissions = submissionSizesByID.values.reduce(0, +)

        var rows = [
            AdminStorageRow(label: "Submissions", formatted: humanReadableBytes(submissions)),
            AdminStorageRow(label: "Test Setups", formatted: humanReadableBytes(testSetups)),
            AdminStorageRow(label: "Results & Logs", formatted: humanReadableBytes(results)),
            AdminStorageRow(label: "Static Assets", formatted: humanReadableBytes(publicAssets)),
        ]
        rows.append(
            AdminStorageRow(
                label: "Database",
                formatted: database.map(humanReadableBytes) ?? "—"))

        let total = submissions + testSetups + results + publicAssets + (database ?? 0)

        let assignments = try await assignmentsFetch
        let courses = try await coursesFetch
        let submissionLinks = try await submissionLinksFetch

        // Tally submission count + bytes per test setup.
        var submissionCountBySetup: [String: Int] = [:]
        var submissionBytesBySetup: [String: Int] = [:]
        for link in submissionLinks {
            submissionCountBySetup[link.testSetupID, default: 0] += 1
            if let subID = link.id {
                submissionBytesBySetup[link.testSetupID, default: 0] +=
                    submissionSizesByID[subID] ?? 0
            }
        }
        let codeByCourse = Dictionary(
            courses.compactMap { course in course.id.map { ($0, course.code) } },
            uniquingKeysWith: { first, _ in first })

        let assignmentRows =
            assignments
            .map { assignment -> AdminAssignmentStorageRow in
                let suiteBytes = setupSizesByID[assignment.testSetupID] ?? 0
                let subBytes = submissionBytesBySetup[assignment.testSetupID] ?? 0
                let count = submissionCountBySetup[assignment.testSetupID] ?? 0
                let rowTotal = suiteBytes + subBytes
                return AdminAssignmentStorageRow(
                    assignmentTitle: assignment.title,
                    courseCode: codeByCourse[assignment.courseID] ?? "—",
                    testSuiteFormatted: humanReadableBytes(suiteBytes),
                    submissionsFormatted: humanReadableBytes(subBytes),
                    submissionCount: count,
                    totalFormatted: humanReadableBytes(rowTotal),
                    testSuiteBytes: suiteBytes,
                    submissionsBytes: subBytes,
                    totalBytes: rowTotal
                )
            }
            .sorted { $0.totalBytes > $1.totalBytes }

        return AdminStorageContext(
            rows: rows,
            totalFormatted: humanReadableBytes(total),
            dbBackend: app.appConfig.database.backend.rawValue,
            assignments: assignmentRows,
            totalBytes: total,
            // The course key, not the bare code: a clone for a new term has
            // its source's code (docs/course-terms.md).
            libraries: try await courseLibraryRows(
                keyByCourse: Dictionary(
                    courses.compactMap { course in course.id.map { ($0, course.urlKey) } },
                    uniquingKeysWith: { first, _ in first }),
                on: app.db)
        )
    }

    /// One row per course with a dataset library, largest first. The sizes
    /// come from the version rows, so no disk walk is needed. Within a course
    /// a hash counts once, as its blob is stored once; a cloned course counts
    /// the hashes it shares with its source again, because each course's row
    /// is what that course would free.
    static func courseLibraryRows(
        keyByCourse: [UUID: String], on db: any Database
    ) async throws -> [AdminCourseLibraryStorageRow] {
        let datasets = try await APICourseDataset.query(on: db).all()
        guard !datasets.isEmpty else { return [] }
        let courseByDataset = Dictionary(
            datasets.compactMap { dataset in dataset.id.map { ($0, dataset.courseID) } },
            uniquingKeysWith: { first, _ in first })
        var datasetCount: [UUID: Int] = [:]
        for dataset in datasets { datasetCount[dataset.courseID, default: 0] += 1 }
        var versionCount: [UUID: Int] = [:]
        var bytesByHash: [UUID: [String: Int]] = [:]
        for version in try await APICourseDatasetVersion.query(on: db).all() {
            guard let courseID = courseByDataset[version.datasetID] else { continue }
            versionCount[courseID, default: 0] += 1
            bytesByHash[courseID, default: [:]][version.sha256] = version.sizeBytes
        }
        return datasetCount.map { courseID, count in
            let bytes = bytesByHash[courseID, default: [:]].values.reduce(0, +)
            return AdminCourseLibraryStorageRow(
                courseKey: keyByCourse[courseID] ?? "—", datasetCount: count,
                versionCount: versionCount[courseID] ?? 0, bytes: bytes, formatted: humanReadableBytes(bytes))
        }
        // Bytes descending, then the key ascending.
        .sorted { ($0.bytes, $1.courseKey) > ($1.bytes, $0.courseKey) }
    }
}

/// One course's dataset library on disk: its datasets and versions, and the
/// bytes of its distinct version files.
struct AdminCourseLibraryStorageRow: Encodable, Sendable, Equatable {
    /// The course key ("CS135-F26"), which names one offering.
    let courseKey: String
    let datasetCount: Int
    let versionCount: Int
    let bytes: Int
    let formatted: String

    /// "2 datasets · 5 versions"
    var detailsText: String {
        let datasets = datasetCount == 1 ? "1 dataset" : "\(datasetCount) datasets"
        let versions = versionCount == 1 ? "1 version" : "\(versionCount) versions"
        return "\(datasets) · \(versions)"
    }
}

struct AdminStorageRow: Encodable, Sendable {
    let label: String
    let formatted: String
}

/// Per-assignment on-disk footprint: its test-suite (test setup) bytes plus
/// the bytes of every submission graded against that setup.  Sorted largest-
/// first so an admin can see where space is going.
struct AdminAssignmentStorageRow: Encodable, Sendable {
    let assignmentTitle: String
    let courseCode: String
    let testSuiteFormatted: String
    let submissionsFormatted: String
    let submissionCount: Int
    let totalFormatted: String
    /// Raw bytes behind the formatted columns — drive the server-side sort and
    /// the client-side column sorting (so "1.4 GB" sorts above "320 MB").
    let testSuiteBytes: Int
    let submissionsBytes: Int
    let totalBytes: Int
}

struct AdminStorageContext: Encodable, Sendable {
    let rows: [AdminStorageRow]
    let totalFormatted: String
    let dbBackend: String
    let assignments: [AdminAssignmentStorageRow]
    /// Raw bytes behind `totalFormatted`, the denominator of each assignment's
    /// share. Zero when a caller does not know it.
    var totalBytes: Int = 0
    /// Free and total space on the data disk, measured on each request rather
    /// than cached with the totals above. Nil when the system does not report it.
    var disk: DiskSpace?
    /// `disk` as the page's "Disk free" tile shows it.
    var diskText: String { disk?.freeOfTotalText ?? "unknown" }
    /// The course dataset libraries, largest first. Their bytes are inside
    /// the "Test Setups" total, as blobs under its directory.
    var libraries: [AdminCourseLibraryStorageRow] = []

    private enum CodingKeys: String, CodingKey {
        case rows, totalFormatted, dbBackend, assignments, totalBytes, disk, diskText, libraries
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(rows, forKey: .rows)
        try container.encode(totalFormatted, forKey: .totalFormatted)
        try container.encode(dbBackend, forKey: .dbBackend)
        try container.encode(assignments, forKey: .assignments)
        try container.encode(totalBytes, forKey: .totalBytes)
        try container.encodeIfPresent(disk, forKey: .disk)
        try container.encode(diskText, forKey: .diskText)
        try container.encode(libraries, forKey: .libraries)
    }
}
