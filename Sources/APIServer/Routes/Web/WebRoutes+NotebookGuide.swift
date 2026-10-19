// APIServer/Routes/Web/WebRoutes+NotebookGuide.swift
//
// GET /testsetups/:id/notebook-guide.json — the student guide the notebook
// editor shows beside each task (`NotebookGuide`, notebook views brief NB3).
//
// It reads results that already exist and runs nothing. It is the viewer's
// own guide: their latest submission and their personalized starter. The
// guide itself is built by `NotebookGuideBuilder`, which decides what a
// student may see; this route only gathers the inputs and caches the answer.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {

    @Sendable
    func notebookGuide(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else { throw AppError.unauthenticated }
        guard
            let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw AppError.notFound(resource: "Test setup")
        }
        try await req.cachedRequireCourseEnrollment(caller: user, courseID: setup.courseID)
        // The notebook source's gate: a student may not read a closed lab they
        // never opened, and the guide carries its starter code.
        let isStaff = try await req.cachedIsCourseStaff(user, inCourse: setup.courseID)
        if !isStaff,
            let assignment = try await assignmentByTestSetupID(setupID, on: req.db),
            !(try await isAssignmentEffectivelyOpen(assignment, for: user, req: req)),
            !(try await studentHasOpenedAssignment(assignment: assignment, userID: userID, on: req.db))
        {
            throw AppError.forbidden(action: "read the guide for an assignment that is not open")
        }
        guard let manifest = setup.decodedManifest() else { throw AppError.notFound(resource: "Assignment manifest") }

        let latest = try await APISubmission.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$userID == userID)
            .filter(\.$kind == APISubmission.Kind.student)
            .sort(\.$attemptNumber, .descending)
            .sort(\.$submittedAt, .descending)
            .first()
        var attempt: NotebookGuideBuilder.AttemptInput?
        if let latest, let submissionID = latest.id {
            var collection: TestOutcomeCollection?
            if latest.status == SubmissionStatus.complete.rawValue {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                collection = try await loadDisplayResultAndCollection(
                    subID: submissionID, decoder: decoder, on: req.db
                ).1
            }
            attempt = NotebookGuideBuilder.AttemptInput(
                submissionID: submissionID, number: latest.attemptNumber ?? 1, collection: collection)
        }

        let key = NotebookGuideCache.Key(
            userID: userID, setupID: setupID, submissionID: attempt?.submissionID,
            graded: attempt?.collection != nil, manifestDigest: sha256HexDigest(setup.manifest))
        let finalAttempt = attempt
        let guide = try await req.application.notebookGuideCache.guide(for: key) {
            let inputs = try await self.guideInputs(req: req, setup: setup, manifest: manifest, userID: userID)
            return NotebookGuideBuilder(
                manifest: manifest, solution: inputs.solution, starter: inputs.starter,
                scriptSources: inputs.scripts, attempt: finalAttempt
            ).build()
        }

        let response = Response(status: .ok)
        try response.content.encode(guide, as: .json)
        // The guide is per student and changes when grading finishes.
        response.headers.replaceOrAdd(name: .cacheControl, value: "private, no-store")
        return response
    }

    /// What the builder reads from disk: the solution's definitions, this
    /// student's personalized starter and the hand-written scripts. The
    /// workbench preview (NB6b) reads the same inputs for the student it
    /// shows.
    func guideInputs(
        req: Request, setup: APITestSetup, manifest: TestProperties, userID: UUID
    ) async throws -> (solution: NotebookDefinitionScan, starter: Data?, scripts: [String: String]) {
        let language = AssignmentLanguage.resolve(manifest: manifest)
        let assignment = try await assignmentByTestSetupID(setup.id ?? "", on: req.db)
        // Server-side only: the solution decides which name a script test is
        // anchored to, and no byte of it reaches the response.
        var solutionData: Data?
        do {
            solutionData = try await solutionNotebookData(
                for: assignment, setup: setup, db: req.db,
                testSetupsDirectory: req.application.testSetupsDirectory)
        } catch {
            req.logger.debug("notebook_guide no_solution setup=\(setup.id ?? "-"): \(error)")
        }
        let starter = await personalizedStarterNotebook(
            setup: setup, userID: userID, on: req.db, application: req.application, logger: req.logger)
        // No solution yet: the starter has the same headings and, usually, the
        // same function stubs, so it gives the anchors instead. With neither,
        // every test is unlinked.
        let anchorSource = solutionData ?? starter
        let solution =
            anchorSource.map { scanNotebookDefinitions($0, language: language) }
            ?? NotebookDefinitionScan(definitions: [], sections: [], codeCellIndices: [])
        var scripts: [String: String] = [:]
        for entry in manifest.testSuites where !entry.isGenerated {
            scripts[entry.script] = await readScriptFromZip(zipPath: setup.zipPath, filename: entry.script)
        }
        return (solution, starter, scripts)
    }
}
