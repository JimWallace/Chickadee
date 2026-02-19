// APIServer/Routes/TestSetupRoutes.swift
//
// Phase 2: test-setup management endpoints.
//
// POST /api/v1/testsetups
//   Multipart: field "manifest" (JSON text) + field "files" (zip binary).
//   Validates the manifest, stores the zip on disk, records metadata in DB.
//   Returns {"testSetupID": "..."}  (201 Created).
//
// GET /api/v1/testsetups/:id/download
//   Streams the stored zip back to the caller.

import Vapor
import Fluent
import Core
import Foundation

struct TestSetupRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "testsetups")
        api.post(use: uploadTestSetup)
        api.group(":testSetupID") { group in
            group.get("download", use: downloadTestSetup)
        }
    }

    // MARK: - POST /api/v1/testsetups

    @Sendable
    func uploadTestSetup(req: Request) async throws -> Response {
        let upload = try req.content.decode(TestSetupUpload.self)

        // Validate manifest JSON and schema version.
        let manifestData = Data(upload.manifest.utf8)
        let decoder      = JSONDecoder()
        let manifest: TestProperties
        do {
            manifest = try decoder.decode(TestProperties.self, from: manifestData)
        } catch {
            throw Abort(.unprocessableEntity, reason: "Invalid manifest JSON: \(error)")
        }
        guard manifest.schemaVersion == 1 else {
            throw Abort(.unprocessableEntity, reason: "Unsupported schemaVersion \(manifest.schemaVersion); expected 1")
        }
        guard !manifest.testSuites.isEmpty else {
            throw Abort(.unprocessableEntity, reason: "Manifest must contain at least one test suite")
        }

        // Persist the zip.
        let setupsDir = req.application.testSetupsDirectory
        let setupID   = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath   = setupsDir + "\(setupID).zip"

        let zipBytes  = upload.files
        try zipBytes.write(to: URL(fileURLWithPath: zipPath))

        // Store metadata in DB.
        let encoder = JSONEncoder()
        let storedManifest = String(data: try encoder.encode(manifest), encoding: .utf8) ?? upload.manifest

        let setup = APITestSetup(
            id:       setupID,
            manifest: storedManifest,
            zipPath:  zipPath
        )
        try await setup.save(on: req.db)

        req.logger.info("Stored test setup \(setupID)")

        let responseBody = try JSONEncoder().encode(["testSetupID": setupID])
        return Response(
            status: .created,
            headers: ["Content-Type": "application/json"],
            body: .init(data: responseBody)
        )
    }

    // MARK: - GET /api/v1/testsetups/:id/download

    @Sendable
    func downloadTestSetup(req: Request) async throws -> Response {
        guard let setupID = req.parameters.get("testSetupID"),
              let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return req.fileio.streamFile(at: setup.zipPath)
    }
}

// MARK: - Multipart form

struct TestSetupUpload: Content {
    /// Raw JSON text of the TestProperties.
    var manifest: String
    /// Raw bytes of the test-setup zip file.
    var files: Data
}
