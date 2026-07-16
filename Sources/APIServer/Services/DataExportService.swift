// APIServer/Services/DataExportService.swift
//
// Personal-data export pipeline (#557 — FIPPA / PIPEDA subject access).
// A request (POST /account/export) resets the user's `data_exports` row to
// pending and hands generation to `DataExportManager`, which runs it in a
// background task: gather from the DB (`gatherDataExportContent`), stage
// files + copies on the thread pool, zip, install the zip under
// `Application.dataExportsDirectory`, and mark the row complete/failed.
// Generation is asynchronous by design — a submission-heavy account can
// take well over the few seconds a request should hold.
//
// What goes inside the zip is defined in `DataExportContent.swift`;
// retention of the generated zips is `DataExportRetentionService.swift`.

import Core
import Fluent
import Foundation
import Vapor

/// One export per user per day (#557).  Enforced against the row's
/// `requestedAt`, which the request handler resets in place.
let dataExportMinRequestInterval: TimeInterval = 24 * 60 * 60

/// A pending row older than this is treated as interrupted (e.g. the server
/// restarted mid-generation, orphaning the row) and may be re-requested.
let dataExportStalePendingAge: TimeInterval = 15 * 60

/// Whether a new export may be requested given the user's current row
/// (nil = no row yet).  Shared by the POST handler (enforcement) and the
/// account page (whether to render the request button).
func dataExportCanBeRequested(_ export: APIDataExport?, now: Date = Date()) -> Bool {
    guard let export else { return true }
    switch export.statusValue {
    case .pending:
        return now.timeIntervalSince(export.requestedAt) >= dataExportStalePendingAge
    case .complete:
        return now.timeIntervalSince(export.requestedAt) >= dataExportMinRequestInterval
    case .failed, nil:
        return true
    }
}

// MARK: - Manager

/// Serializes export generation per user on this process: a second request
/// for a user whose generation is still in flight is a no-op (the DB row is
/// already pending and the running task will complete it).
actor DataExportManager {
    private var inFlightUserIDs: Set<UUID> = []

    /// Starts generation for `userID` unless one is already running here.
    /// Returns whether a new generation task was started.
    @discardableResult
    func startExport(exportID: UUID, userID: UUID, app: Application) -> Bool {
        guard !inFlightUserIDs.contains(userID) else { return false }
        inFlightUserIDs.insert(userID)
        Task {
            await generateDataExport(exportID: exportID, userID: userID, app: app)
            markFinished(userID: userID)
        }
        return true
    }

    private func markFinished(userID: UUID) {
        inFlightUserIDs.remove(userID)
    }
}

struct DataExportManagerKey: StorageKey {
    typealias Value = DataExportManager
}

extension Application {
    var dataExportManager: DataExportManager {
        get {
            if let existing = storage[DataExportManagerKey.self] {
                return existing
            }
            let created = DataExportManager()
            storage[DataExportManagerKey.self] = created
            return created
        }
        set {
            storage[DataExportManagerKey.self] = newValue
        }
    }
}

// MARK: - Generation

/// Runs one export end-to-end and stamps the row's terminal state.  Never
/// throws — a failure marks the row failed (with an operator-facing reason)
/// and logs; the user sees a generic "failed, try again".
func generateDataExport(exportID: UUID, userID: UUID, app: Application) async {
    do {
        try await buildDataExport(exportID: exportID, userID: userID, app: app)
        app.logger.info("data_export complete user=\(userID.uuidString)")
    } catch {
        app.logger.error(
            "data_export generation failed user=\(userID.uuidString): \(String(reflecting: error))"
        )
        await markExportFailed(exportID: exportID, error: error, app: app)
    }
}

private func buildDataExport(exportID: UUID, userID: UUID, app: Application) async throws {
    let db = app.db
    guard let user = try await APIUser.find(userID, on: db) else {
        throw Abort(.notFound, reason: "User \(userID.uuidString) not found for data export")
    }

    let generatedAt = Date()
    let content = try await gatherDataExportContent(for: user, on: db, now: generatedAt)
    let files = try stagedExportFiles(
        content: content, username: user.username, generatedAt: generatedAt)
    let copies = content.fileCopies.map {
        DataExportStagedCopy(sourcePath: $0.sourcePath, relativePath: $0.relativePath)
    }

    let stagingDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("chickadee-data-export-\(UUID().uuidString)")
    let tempZipPath = stagingDir.path + ".zip"
    let finalZipPath = app.dataExportsDirectory + "\(userID.uuidString).zip"
    defer {
        try? FileManager.default.removeItem(at: stagingDir)
        if FileManager.default.fileExists(atPath: tempZipPath) {
            try? FileManager.default.removeItem(atPath: tempZipPath)
        }
    }

    let logger = app.logger
    try await runBlocking(app: app) {
        try writeDataExportStaging(
            stagingDir: stagingDir, files: files, copies: copies, logger: logger)
    }
    try await createZipArchive(sourceDir: stagingDir, outputPath: tempZipPath)
    let fileSize = try await runBlocking(app: app) {
        try installDataExportZip(tempZipPath: tempZipPath, finalZipPath: finalZipPath)
    }

    guard let row = try await APIDataExport.find(exportID, on: db) else { return }
    row.setStatus(.complete)
    row.completedAt = Date()
    row.zipPath = finalZipPath
    row.fileSizeBytes = fileSize
    row.failureReason = nil
    try await row.save(on: db)
}

/// The fixed JSON/Markdown files at the root of the zip, plus one
/// `results.json` per submission that has stored outcomes.
private func stagedExportFiles(
    content: DataExportContent, username: String, generatedAt: Date
) throws -> [DataExportStagedFile] {
    let encoder = dataExportJSONEncoder()
    var files: [DataExportStagedFile] = [
        .init(
            relativePath: "README.md",
            data: Data(dataExportReadme(username: username, generatedAt: generatedAt).utf8)),
        .init(relativePath: "profile.json", data: try encoder.encode(content.profile)),
        .init(relativePath: "enrollments.json", data: try encoder.encode(content.enrollments)),
        .init(relativePath: "submissions.json", data: try encoder.encode(content.submissions)),
        .init(
            relativePath: "grading-adjustments.json",
            data: try encoder.encode(content.gradingAdjustments)),
        .init(relativePath: "audit-log.json", data: try encoder.encode(content.auditEntries)),
    ]
    for (path, data) in content.resultFiles.sorted(by: { $0.key < $1.key }) {
        files.append(.init(relativePath: path, data: data))
    }
    return files
}

private func markExportFailed(exportID: UUID, error: Error, app: Application) async {
    guard let row = try? await APIDataExport.find(exportID, on: app.db),
        row.statusValue == .pending
    else { return }
    row.setStatus(.failed)
    row.completedAt = Date()
    row.failureReason = String(String(reflecting: error).prefix(500))
    do {
        try await row.save(on: app.db)
    } catch {
        app.logger.error(
            "data_export failed-state save failed for \(exportID): \(error.localizedDescription)"
        )
    }
}

// MARK: - Staging (thread-pool file I/O over Sendable primitives)

struct DataExportStagedFile: Sendable {
    let relativePath: String
    let data: Data
}

struct DataExportStagedCopy: Sendable {
    let sourcePath: String
    let relativePath: String
}

/// Builds the staging tree: writes every in-memory file and copies every
/// on-disk submission file, creating intermediate directories as needed.
/// Free function over Sendable values so it can run on the thread pool
/// (same shape as the course-bundle export's `writeExportStaging`).
private func writeDataExportStaging(
    stagingDir: URL,
    files: [DataExportStagedFile],
    copies: [DataExportStagedCopy],
    logger: Logger
) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: stagingDir, withIntermediateDirectories: true)

    for file in files {
        let dst = stagingDir.appendingPathComponent(file.relativePath)
        try fm.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.data.write(to: dst)
    }

    for copy in copies {
        let src = URL(fileURLWithPath: copy.sourcePath)
        let dst = stagingDir.appendingPathComponent(copy.relativePath)
        try fm.createDirectory(
            at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: src.path) {
            try fm.copyItem(at: src, to: dst)
        } else {
            // Listed as included at gather time but gone now (e.g. purged
            // concurrently) — skip; the index entry simply points at a
            // missing path, matching the course-bundle export's behaviour.
            logger.warning("data_export: submission file missing at \(src.path), skipping")
        }
    }
}

/// Moves the freshly-built zip into its final location, replacing any
/// previous export, and returns its size in bytes.  `zip -r` appends into
/// an existing archive, so the build always targets a fresh temp path and
/// installs with remove + move.
private func installDataExportZip(tempZipPath: String, finalZipPath: String) throws -> Int {
    let fm = FileManager.default
    if fm.fileExists(atPath: finalZipPath) {
        try fm.removeItem(atPath: finalZipPath)
    }
    try fm.moveItem(atPath: tempZipPath, toPath: finalZipPath)
    let attributes = try fm.attributesOfItem(atPath: finalZipPath)
    return (attributes[.size] as? Int) ?? 0
}
