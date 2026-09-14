// APIServer/Routes/Web/InstructorDashboardRoutes+SubmissionsDownload.swift
//
// One zip of every enrolled student's latest submission for an assignment
// (GET /instructor/:assignmentID/submissions.zip), for offline marking or a
// similarity-detection run.
//
// Latest, not best: the file a student handed in last is the one they
// consider current, and a marking pass reads the work rather than the
// grade. The best grade is the roster's concern and stays on the page.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorDashboardRoutes {

    // MARK: - GET /instructor/:assignmentID/submissions.zip

    @Sendable
    func downloadAssignmentSubmissions(req: Request) async throws -> Response {
        let assignment = try await loadAssignmentForStaffRead(req)
        let studentIDs = Array(try await studentUserIDsInCourse(assignment.courseID, on: req.db))
        let summaries = try await submissionSummaryByStudent(
            setupID: assignment.testSetupID, studentIDs: studentIDs, on: req.db)
        guard !summaries.isEmpty else {
            return req.redirect(
                to: "/instructor/\(assignment.publicID)/submissions?error=No+submissions+to+download")
        }

        let usernameByID = Dictionary(
            try await APIUser.query(on: req.db)
                .filter(\.$id ~~ Array(summaries.keys))
                .all()
                .compactMap { user in user.id.map { ($0, user.username) } },
            uniquingKeysWith: { first, _ in first })
        let latest = try await APISubmission.query(on: req.db)
            .filter(\.$id ~~ summaries.values.map(\.latestSubmissionID))
            .all()

        // Reduce to primitives before the thread-pool hop: Fluent models are
        // not Sendable (#1158). Sorted by username so the index is stable.
        let stamp = ISO8601DateFormatter()
        let entries: [StagedSubmission] = latest.compactMap { submission in
            guard let userID = submission.userID, let username = usernameByID[userID] else {
                return nil
            }
            let onDiskName = URL(fileURLWithPath: submission.zipPath).lastPathComponent
            return StagedSubmission(
                username: username,
                directory: sanitizedDownloadComponent(username),
                submissionID: submission.id ?? "",
                attemptNumber: submission.attemptNumber ?? 0,
                submittedAt: submission.submittedAt.map(stamp.string(from:)) ?? "",
                sourcePath: submission.zipPath,
                filename: sanitizedDownloadComponent(submission.filename ?? onDiskName))
        }.sorted { $0.username < $1.username }

        let stagingDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-submissions-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingDir) }
        let logger = req.logger
        try await runBlocking(on: req) {
            try writeSubmissionsStaging(stagingDir: stagingDir, entries: entries, logger: logger)
        }

        let safeSlug = sanitizedDownloadComponent(assignment.slug)
        let zipName = "chickadee-submissions-\(safeSlug)-\(stamp.string(from: Date()).prefix(10)).zip"
        let zipPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString)-\(zipName)").path
        try await createZipArchive(sourceDir: stagingDir, outputPath: zipPath)

        await AuditLogger.record(
            action: .submissionsBulkDownloaded,
            targetType: .assignment,
            targetID: assignment.id?.uuidString,
            metadata: ["assignment": assignment.publicID, "count": String(entries.count)],
            on: req
        )
        do {
            return try await streamTemporaryZip(req: req, zipPath: zipPath, downloadName: zipName)
        } catch {
            try? FileManager.default.removeItem(atPath: zipPath)
            throw error
        }
    }
}

/// One student's latest submission, reduced to what staging needs.
struct StagedSubmission: Sendable {
    let username: String
    let directory: String
    let submissionID: String
    let attemptNumber: Int
    let submittedAt: String
    let sourcePath: String
    let filename: String
}

/// Lays out `<directory>/<filename>` per student plus an `index.csv` naming
/// each file's owner, attempt and submission time. A missing artifact is
/// logged and skipped rather than failing the whole download — one lost
/// file must not block marking the other two hundred.
func writeSubmissionsStaging(stagingDir: URL, entries: [StagedSubmission], logger: Logger) throws {
    try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)
    var index: [String] = ["username,submission_id,attempt,submitted_at,path"]
    for entry in entries {
        let src = URL(fileURLWithPath: entry.sourcePath)
        guard FileManager.default.fileExists(atPath: src.path) else {
            logger.warning("Submissions download: artifact missing at \(src.path), skipping")
            continue
        }
        let dir = stagingDir.appendingPathComponent(entry.directory, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: src, to: dir.appendingPathComponent(entry.filename))
        let relativePath = "\(entry.directory)/\(entry.filename)"
        index.append(
            [entry.username, entry.submissionID, String(entry.attemptNumber), entry.submittedAt, relativePath]
                .map(csvEscaped).joined(separator: ","))
    }
    try (index.joined(separator: "\n") + "\n")
        .write(to: stagingDir.appendingPathComponent("index.csv"), atomically: true, encoding: .utf8)
}
