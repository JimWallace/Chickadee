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

        // A validation (reference-solution) notebook carrying `{{name}}`
        // personalization placeholders is substituted ONCE at enqueue
        // (`materializeValidationGrading`) into a `<zipPath>.grading` sidecar.
        // Stream that pre-substituted copy when present, so this route stays
        // pure I/O — no manifest decode, no seed lookup, no `python3`. That's
        // what keeps it under the runner's tight download timeout (the `#869`
        // regression ran the evaluator here and tripped a 5 s `-1001`).
        //
        // The stored `zipPath` keeps its `{{...}}` template, so `get_solution`,
        // the editor, and re-validation by another user still see the source.
        // When no sidecar exists (non-personalized assignment, or materialization
        // didn't run) we stream the stored file verbatim, exactly as before.
        if submission.kind == APISubmission.Kind.validation {
            let gradingCopy = submission.zipPath + ".grading"
            if FileManager.default.fileExists(atPath: gradingCopy) {
                return try await req.fileio.asyncStreamFile(at: gradingCopy)
            }
        }

        return try await req.fileio.asyncStreamFile(at: submission.zipPath)
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
