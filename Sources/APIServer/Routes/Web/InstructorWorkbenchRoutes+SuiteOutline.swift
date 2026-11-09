// APIServer/Routes/Web/InstructorWorkbenchRoutes+SuiteOutline.swift
//
//   GET /instructor/:assignmentID/suite-outline.json → `InstructorSuiteOutline`
//
// The workbench rail (NB6) draws it, and NB7's margin cards read it. Course
// staff only, through the same gate as the workbench page: it names hidden
// tests and the solution's results.

import Core
import Fluent
import Foundation
import Vapor

extension InstructorWorkbenchRoutes {
    @Sendable
    func suiteOutline(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        guard let manifest = decodeManifest(fromJSON: setup.manifest) else {
            throw AppError.unprocessable(reason: "The assignment's manifest cannot be read.")
        }
        let language = AssignmentLanguage.resolve(manifest: manifest)

        // The solution decides a script test's anchor, or the starter when
        // there is no solution yet (`SuiteAnchorResolution`, shared with MCP).
        let notebook = await SuiteAnchorResolution.notebookScan(
            assignment: assignment, setup: setup, language: language, db: req.db,
            testSetupsDirectory: req.application.testSetupsDirectory)

        let scripts = await req.application.zipScriptTextCache.texts(
            zipPath: setup.zipPath, filenames: manifest.testSuites.map(\.script))

        let outline = InstructorSuiteOutlineBuilder(
            manifest: manifest, notebook: notebook, scriptSources: scripts,
            validationStatus: assignment.validationStatus,
            solutionRun: try await latestSolutionRun(for: assignment, on: req.db),
            starterRun: try await StarterValidationRun.latest(setupID: setup.requireID(), on: req.db)
        ).build()

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let response = Response(status: .ok, body: .init(data: try encoder.encode(outline)))
        response.headers.contentType = .json
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return response
    }

    /// The last validation run's outcomes. A validation submission runs the
    /// reference solution, never a student's work.
    private func latestSolutionRun(
        for assignment: APIAssignment, on db: any Database
    ) async throws -> TestOutcomeCollection? {
        var submission: APISubmission?
        if let id = assignment.validationSubmissionID, let linked = try await APISubmission.find(id, on: db),
            linked.kind == APISubmission.Kind.validation
        {
            submission = linked
        } else {
            submission = try await APISubmission.query(on: db)
                .filter(\.$testSetupID == assignment.testSetupID)
                .filter(\.$kind == APISubmission.Kind.validation)
                .sort(\.$submittedAt, .descending)
                .first()
        }
        guard let submissionID = try submission?.requireID(),
            let result = try await APIResult.query(on: db)
                .filter(\.$submissionID == submissionID)
                .sort(\.$receivedAt, .descending)
                .first(),
            let json = try await result.loadCollectionJSON(on: db)
        else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TestOutcomeCollection.self, from: Data(json.utf8))
    }
}
