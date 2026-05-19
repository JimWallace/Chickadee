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
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        let data = try notebookData(for: setup)
        let downloadName = currentSetupFiles(
            for: setup,
            assignmentID: idStr,
            solutionFilename: nil
        ).assignmentFile.name
        return buildFileResponse(data: data, filename: downloadName)
    }

    // MARK: - GET /instructor/:assignmentID/files/item?name=<filename>

    @Sendable
    func downloadCurrentSetupItem(req: Request) async throws -> Response {
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

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
        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else {
            throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
        }

        // Look for a solution.* entry inside the test setup zip.
        let solutionZipEntry = listZipEntries(zipPath: setup.zipPath)
            .first(where: { $0.hasPrefix("solution.") })
        if let entryName = solutionZipEntry,
            let data = extractZipEntry(zipPath: setup.zipPath, entryName: entryName)
        {
            return buildFileResponse(data: data, filename: entryName)
        }

        // Fall back to the most recent validation submission, preserving
        // the instructor's original filename (e.g. bmi.py, dna.py).
        if let validationID = assignment.validationSubmissionID,
            let validationSubmission = try await APISubmission.find(validationID, on: req.db),
            let data = try? Data(contentsOf: URL(fileURLWithPath: validationSubmission.zipPath)),
            !data.isEmpty
        {
            return buildFileResponse(data: data, filename: validationSubmission.filename ?? "solution.ipynb")
        }

        if let fallbackSubmission = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == assignment.testSetupID)
            .filter(\.$kind == APISubmission.Kind.validation)
            .sort(\.$submittedAt, .descending)
            .first(),
            let data = try? Data(contentsOf: URL(fileURLWithPath: fallbackSubmission.zipPath)),
            !data.isEmpty
        {
            return buildFileResponse(data: data, filename: fallbackSubmission.filename ?? "solution.ipynb")
        }

        throw WebAssignmentError.notFound(resource: "Solution notebook for this assignment")
    }
}
