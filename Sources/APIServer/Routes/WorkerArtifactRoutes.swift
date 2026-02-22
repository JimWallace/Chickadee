import Vapor
import Fluent

/// Worker-only artifact download routes authenticated by X-Worker-Secret.
struct WorkerArtifactRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let worker = routes.grouped("api", "v1", "worker")
        worker.get("submissions", ":submissionID", "download", use: downloadSubmission)
        worker.get("testsetups", ":testSetupID", "download", use: downloadTestSetup)
    }

    @Sendable
    func downloadSubmission(req: Request) async throws -> Response {
        try await requireWorkerSecret(req)

        guard let subID = req.parameters.get("submissionID"),
              let submission = try await APISubmission.find(subID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: submission.zipPath)
    }

    @Sendable
    func downloadTestSetup(req: Request) async throws -> Response {
        try await requireWorkerSecret(req)

        guard let setupID = req.parameters.get("testSetupID"),
              let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: setup.zipPath)
    }
}
