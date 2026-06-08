import Core
import Fluent
import Foundation
import Vapor

/// Worker-only artifact download routes authenticated by X-Worker-Secret.
struct WorkerArtifactRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let worker = routes.grouped("api", "v1", "worker")
        worker.get("submissions", ":submissionID", "download", use: downloadSubmission)
        worker.get("testsetups", ":testSetupID", "download", use: downloadTestSetup)
    }

    @Sendable
    func downloadSubmission(req: Request) async throws -> Response {
        guard let subID = req.parameters.get("submissionID"),
            let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // A reference-solution (validation) notebook may carry the same
        // `{{name}}` personalization placeholders as the student starter — e.g.
        // `fortuneShift = {{fortuneShift}}` so the answer key derives a
        // per-student value exactly the way a student would. Substitute them
        // here, at worker download, using the SAME per-(user, assignment) seed
        // the worker resolves for `_ck_inputs.py`
        // (`WorkerJobRoutes.buildJobPayload`), so the solution's per-student
        // values and the grader's expected values agree. The stored file keeps
        // its `{{...}}` template, so `get_solution` and re-validation by any
        // user still see the editable source.
        //
        // This is gated to validation submissions: student submissions are
        // already-substituted working copies (substituted at notebook
        // first-open), so they must not be re-processed here.
        if submission.kind == APISubmission.Kind.validation,
            let substituted = try? await substitutedValidationNotebook(req: req, submission: submission)
        {
            let response = Response(status: .ok)
            response.headers.contentType = HTTPMediaType(type: "application", subType: "octet-stream")
            response.body = .init(data: substituted)
            return response
        }

        return try await req.fileio.asyncStreamFile(at: submission.zipPath)
    }

    /// Returns the validation submission's notebook with `{{name}}`
    /// placeholders substituted for the submission's seed, or `nil` when there
    /// is nothing to do — not an `.ipynb`, no personalization declared on the
    /// setup, or no substitutions resolved. On `nil` the caller streams the
    /// stored file verbatim (the historical behaviour), so an assignment with
    /// no personalization is completely unaffected.
    ///
    /// The seed is resolved with the SAME `AssignmentSeedStore.ensureSeed(user,
    /// assignment)` the worker uses to build `_ck_inputs.py`, keyed on the
    /// submission's own `userID`, so the substituted answer key matches the
    /// grader's per-student expected values for this exact validation run.
    private func substitutedValidationNotebook(
        req: Request, submission: APISubmission
    ) async throws -> Data? {
        guard (submission.filename ?? "solution.ipynb").lowercased().hasSuffix(".ipynb") else {
            return nil
        }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: submission.zipPath)),
            !data.isEmpty
        else { return nil }

        let setupID = submission.testSetupID
        guard let setup = try await APITestSetup.find(setupID, on: req.db),
            let manifestData = setup.manifest.data(using: .utf8),
            let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: manifestData)
        else { return nil }

        // Skip the work entirely unless the setup actually declares
        // personalization — keeps non-personalized assignments on the original
        // zero-copy streaming path.
        let hasPersonalization =
            !manifest.globalVariables.isEmpty
            || !manifest.globalExpressions.isEmpty
            || manifest.sections.contains { !$0.variables.isEmpty || !$0.expressions.isEmpty }
        guard hasPersonalization else { return nil }

        // Resolve the same per-(user, assignment) seed the worker uses for
        // `_ck_inputs.py` so the answer key and the grader agree.
        var seedHex: String?
        if let userID = submission.userID,
            let assignment = try await APIAssignment.query(on: req.db)
                .filter(\.$testSetupID == setupID)
                .first(),
            let assignmentID = assignment.id
        {
            seedHex = try? await AssignmentSeedStore.ensureSeed(
                userID: userID, assignmentID: assignmentID, on: req.db)
        }

        let supportDir = req.application.testSetupsDirectory + "shared/\(setupID)/"
        let resolution = await PersonalizationSubstitution.resolve(
            manifest: manifest, seedHex: seedHex, supportFilesDirectory: supportDir)
        guard !resolution.substitutions.isEmpty else { return nil }

        // Soft-fail: the editor's save-time scan is the authoritative gate for
        // unknown placeholders, so leave any stragglers verbatim rather than
        // throwing here.
        return try? NotebookSubstitution.apply(
            notebookData: data,
            substitutions: resolution.substitutions,
            strict: false
        )
    }

    @Sendable
    func downloadTestSetup(req: Request) async throws -> Response {
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: setup.zipPath)
    }
}
