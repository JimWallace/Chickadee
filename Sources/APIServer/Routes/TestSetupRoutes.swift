// APIServer/Routes/TestSetupRoutes.swift
//
// Phase 2: test-setup management endpoints.
//
// POST /api/v1/testsetups
//   Multipart: field "manifest" (JSON text) + field "files" (zip binary).
//   Validates the manifest, stores the zip on disk, records metadata in DB.
//   For browser-mode setups, also extracts and stores a flat .ipynb file.
//   Returns {"testSetupID": "..."}  (201 Created).
//
// GET /api/v1/testsetups/:id/download
//   Streams the stored zip back to the caller.
//
// GET /api/v1/testsetups/:id/assignment
//   Returns the notebook JSON. Serves the flat .ipynb file if present
//   (browser-mode, possibly edited); falls back to extracting from the zip.
//
// PUT /api/v1/testsetups/:id/assignment   [Phase 8]
//   Body: raw notebook JSON. Saves to disk as testsetups/<id>.ipynb and
//   updates notebookPath in DB. Returns 204 No Content.

import Vapor
import Fluent
import Core
import Foundation

struct TestSetupRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "testsetups")
        api.post(use: uploadTestSetup)
        api.group(":testSetupID") { group in
            group.get("download",    use: downloadTestSetup)
            group.get("assignment",  use: getAssignment)
            group.put("assignment",  use: saveAssignment)   // Phase 8
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

        // For browser-mode: extract and save the flat .ipynb file so the
        // instructor can edit it later without re-uploading the zip.
        if manifest.gradingMode == .browser {
            let notebookPath = setupsDir + "\(setupID).ipynb"
            if let data = extractNotebookFromZip(zipPath: zipPath) {
                try data.write(to: URL(fileURLWithPath: notebookPath))
                setup.notebookPath = notebookPath
                try await setup.save(on: req.db)
                req.logger.info("Saved flat notebook for setup \(setupID) at \(notebookPath)")
            }
        }

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

        // Phase 8: if a flat .ipynb file exists (browser-mode, possibly edited),
        // serve it directly without touching the zip.
        if let notebookPath = setup.notebookPath {
            let url = URL(fileURLWithPath: notebookPath)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else {
                // Fall through to zip extraction if the file is missing/empty.
                req.logger.warning("Flat notebook at \(notebookPath) missing or empty; falling back to zip")
                return try getAssignmentFromZip(setup: setup, req: req)
            }
            return Response(
                status: .ok,
                headers: ["Content-Type": "application/json"],
                body: .init(data: data)
            )
        }

        // Worker-mode (or browser-mode before Phase 8 migration): extract from zip.
        return try getAssignmentFromZip(setup: setup, req: req)
    }

    private func getAssignmentFromZip(setup: APITestSetup, req: Request) throws -> Response {
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

    // MARK: - PUT /api/v1/testsetups/:id/assignment  [Phase 8]

    @Sendable
    func saveAssignment(req: Request) async throws -> HTTPStatus {
        guard let setupID = req.parameters.get("testSetupID"),
              let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Collect the raw request body as Data.
        guard let bodyBuffer = req.body.data,
              bodyBuffer.readableBytes > 0
        else {
            throw Abort(.badRequest, reason: "Request body is empty")
        }
        let notebookData = Data(bodyBuffer.readableBytesView)

        // Basic JSON validation — reject obviously non-JSON bodies.
        guard (try? JSONSerialization.jsonObject(with: notebookData)) != nil else {
            throw Abort(.unprocessableEntity, reason: "Body is not valid JSON")
        }

        // Determine the save path: reuse existing notebookPath or derive from setupID.
        let notebookPath: String
        if let existing = setup.notebookPath {
            notebookPath = existing
        } else {
            notebookPath = req.application.testSetupsDirectory + "\(setupID).ipynb"
        }

        try notebookData.write(to: URL(fileURLWithPath: notebookPath))

        if setup.notebookPath == nil {
            setup.notebookPath = notebookPath
            try await setup.save(on: req.db)
        }

        req.logger.info("Saved edited notebook for setup \(setupID)")
        return .noContent
    }
}

// MARK: - Multipart form

struct TestSetupUpload: Content {
    /// Raw JSON text of the TestProperties.
    var manifest: String
    /// Raw bytes of the test-setup zip file.
    var files: Data
}

// MARK: - Zip inspection helpers

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

/// Extracts `assignment.ipynb` from the zip at `zipPath` and returns its Data,
/// or nil if the file is not present or unzip fails.
func extractNotebookFromZip(zipPath: String) -> Data? {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments     = ["-p", zipPath, "assignment.ipynb"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError  = Pipe()
    guard (try? proc.run()) != nil else { return nil }
    proc.waitUntilExit()
    guard proc.terminationStatus == 0 else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return data.isEmpty ? nil : data
}
