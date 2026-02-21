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
//
// GET /api/v1/testsetups/:id/assignment
//   Extracts assignment.ipynb from the test setup zip and returns it as JSON.

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
            group.get("assignment", use: getAssignment)
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

        // Mode-specific validation.
        switch manifest.gradingMode {
        case .browser:
            guard zipContainsNotebook(upload.files) else {
                throw Abort(.unprocessableEntity, reason: "Browser-mode test setup must contain at least one .ipynb file")
            }
        case .worker:
            guard !manifest.testSuites.isEmpty else {
                throw Abort(.unprocessableEntity, reason: "Worker-mode test setup must contain at least one test suite")
            }
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
        return try await req.fileio.asyncStreamFile(at: setup.zipPath)
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment

    @Sendable
    func getAssignment(req: Request) async throws -> Response {
        guard let setupID = req.parameters.get("testSetupID"),
              let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Extract assignment.ipynb from the zip using unzip -p (prints to stdout).
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments     = ["-p", setup.zipPath, "assignment.ipynb"]

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError  = Pipe()    // discard stderr

        do {
            try proc.run()
        } catch {
            throw Abort(.internalServerError, reason: "Failed to run unzip: \(error)")
        }
        proc.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard proc.terminationStatus == 0, !data.isEmpty else {
            throw Abort(.notFound, reason: "No assignment.ipynb found in this test setup")
        }

        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }
}

// MARK: - Multipart form

struct TestSetupUpload: Content {
    /// Raw JSON text of the TestProperties.
    var manifest: String
    /// Raw bytes of the test-setup zip file.
    var files: Data
}

// MARK: - Zip inspection helper

/// Returns true if the zip archive contains at least one `.ipynb` file.
/// Uses `unzip -l` (list mode) so no files are extracted.
func zipContainsNotebook(_ zipData: Data) -> Bool {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("chickadee_zip_check_\(UUID().uuidString).zip")
    defer { try? FileManager.default.removeItem(at: tmp) }

    guard (try? zipData.write(to: tmp)) != nil else { return false }

    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments     = ["-l", tmp.path]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError  = Pipe()
    guard (try? proc.run()) != nil else { return false }
    proc.waitUntilExit()

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    return output.contains(".ipynb")
}
