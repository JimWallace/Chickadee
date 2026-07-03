// APIServer/Routes/Web/PublishedAssignmentRoutes+FileDownloads.swift
//
// File-download endpoints for the published-assignment editor:
//   GET /instructor/:assignmentID/files/notebook
//   GET /instructor/:assignmentID/files/item?name=<filename>
//   GET /instructor/:assignmentID/files/solution
//
// Split out of `AssignmentRoutes+Editor.swift` in v0.4.183 (Phase 4.2
// of the audit-driven refactor).  No behaviour change.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {
    // MARK: - GET /instructor/:assignmentID/files/notebook

    @Sendable
    func downloadCurrentNotebookFile(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForStaffRead(req)

        let data = try notebookData(for: setup)
        let downloadName = currentSetupFiles(
            for: setup,
            assignmentID: assignment.publicID,
            solutionFilename: nil
        ).assignmentFile.name
        return buildFileResponse(data: data, filename: downloadName)
    }

    // MARK: - GET /instructor/:assignmentID/files/item?name=<filename>

    @Sendable
    func downloadCurrentSetupItem(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetupForStaffRead(req)

        struct FileQuery: Content {
            let name: String
        }
        let q = try req.query.decode(FileQuery.self)
        let fileName = (q.name as NSString).lastPathComponent
        guard !fileName.isEmpty, fileName == q.name else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Invalid file name")
        }

        guard let data = extractZipEntry(zipPath: setup.zipPath, entryName: fileName) else {
            throw WebAssignmentError.notFound(resource: "File '\(fileName)' in setup")
        }
        return buildFileResponse(data: data, filename: fileName)
    }

    // MARK: - GET /instructor/:assignmentID/files/solution

    @Sendable
    func downloadCurrentSolutionFile(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForStaffRead(req)

        // Look for a solution.* entry inside the test setup zip.
        // Cached entry list + off-thread extraction (#1158): both helpers
        // spawn serialized unzip subprocesses.
        let zipPath = setup.zipPath
        let solutionZipEntry = await req.application.zipEntryListCache.entries(zipPath: zipPath)
            .first(where: { $0.hasPrefix("solution.") })
        if let entryName = solutionZipEntry,
            let data = try await runBlocking(on: req, { extractZipEntry(zipPath: zipPath, entryName: entryName) })
        {
            return buildFileResponse(data: data, filename: entryName)
        }

        // Fall back to the most recent validation submission, preserving
        // the instructor's original filename (e.g. bmi.py, dna.py).
        if let validationID = assignment.validationSubmissionID,
            let validationSubmission = try await APISubmission.find(validationID, on: req.db),
            let response = try await streamedFileResponse(
                req: req, path: validationSubmission.zipPath,
                filename: validationSubmission.filename ?? "solution.ipynb")
        {
            return response
        }

        if let fallbackSubmission = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .sort(\.$submittedAt, .descending)
            .first(),
            let response = try await streamedFileResponse(
                req: req, path: fallbackSubmission.zipPath,
                filename: fallbackSubmission.filename ?? "solution.ipynb")
        {
            return response
        }

        throw WebAssignmentError.notFound(resource: "Solution notebook for this assignment")
    }
}

/// Streams a file-backed download with the shared content-type/disposition
/// shape of `buildFileResponse`, or nil when the file is missing/empty so
/// callers can fall through to the next candidate (#1158).
private func streamedFileResponse(
    req: Request, path: String, filename: String
) async throws -> Response? {
    let exists: Bool = try await runBlocking(on: req) {
        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
            !isDirectory.boolValue,
            let attrs = try? FileManager.default.attributesOfItem(atPath: path),
            (attrs[.size] as? UInt64 ?? 0) > 0
        else { return false }
        return true
    }
    guard exists else { return nil }
    let response = try await req.fileio.asyncStreamFile(at: path)
    response.headers.contentType = contentType(for: filename)
    response.headers.replaceOrAdd(
        name: .contentDisposition, value: "attachment; filename=\"\(filename)\"")
    return response
}
