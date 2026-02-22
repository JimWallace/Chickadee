// APIServer/Routes/TestSetupRoutes.swift
//
// Phase 2: test-setup management endpoints.
// Phase 9: notebook cell filtering + download endpoint.
//
// POST /api/v1/testsetups           [instructor only]
//   Multipart: field "manifest" (JSON text) + field "files" (zip binary).
//   Validates the manifest, stores the zip on disk, records metadata in DB.
//   For browser-mode setups, also extracts and stores a flat .ipynb file.
//   Returns {"testSetupID": "..."}  (201 Created).
//
// GET /api/v1/testsetups/:id/download   [instructor only]
//   Streams the stored zip back to the caller.
//
// GET /api/v1/testsetups/:id/assignment   [any authenticated user]
//   Returns the notebook JSON.
//   Instructors: full notebook (all cells).
//   Students: hidden-tier cells (secret, release) stripped.
//
// GET /api/v1/testsetups/:id/assignment/download   [any authenticated user]
//   Downloads the student-filtered notebook as an attachment.
//   Filename: "<Assignment Title>.ipynb" (or "<setupID>.ipynb" as fallback).
//
// PUT /api/v1/testsetups/:id/assignment   [instructor only, Phase 8]
//   Body: raw notebook JSON. Saves to disk as testsetups/<id>.ipynb and
//   updates notebookPath in DB. Returns 204 No Content.

import Vapor
import Fluent
import Core
import Foundation

// MARK: - Notebook cell filtering / merging helpers (free functions)

/// Tiers that students cannot see in the notebook or in downloads.
let hiddenTiersForStudents: Set<String> = ["secret", "release"]

/// Extracts the joined source string for a notebook cell dictionary.
func cellSource(_ cell: [String: Any]) -> String? {
    if let arr = cell["source"] as? [String] { return arr.joined() }
    if let str = cell["source"] as? String   { return str }
    return nil
}

/// Returns true when the cell's first non-empty line is a `# TEST:` comment
/// whose `tier=` value is in `hiddenTiers`.
func isHiddenTestCell(_ cell: [String: Any], hiddenTiers: Set<String>) -> Bool {
    guard let source = cellSource(cell) else { return false }
    let firstLine = source
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first.map(String.init) ?? ""
    guard firstLine.range(of: #"^#\s*TEST:"#, options: .regularExpression) != nil
    else { return false }
    for token in firstLine.split(separator: " ") {
        let kv = token.split(separator: "=", maxSplits: 1)
        if kv.count == 2, kv[0] == "tier" {
            return hiddenTiers.contains(String(kv[1]))
        }
    }
    return false    // no explicit tier= found → default "public" → not hidden
}

/// Returns true when the cell's first non-empty line is ANY `# TEST:` comment,
/// regardless of tier. Used to separate solution cells from test cells during merge.
func isTestCell(_ cell: [String: Any]) -> Bool {
    guard let source = cellSource(cell) else { return false }
    let firstLine = source
        .split(separator: "\n", omittingEmptySubsequences: true)
        .first.map(String.init) ?? ""
    return firstLine.range(of: #"^#\s*TEST:"#, options: .regularExpression) != nil
}

/// Returns a copy of `data` (notebook JSON) with cells matching `hiddenTiers` removed.
/// Returns the original data unchanged if parsing fails.
func filterNotebook(_ data: Data, hiddenTiers: Set<String>) -> Data {
    guard var nb    = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let cells = nb["cells"] as? [[String: Any]]
    else { return data }
    nb["cells"] = cells.filter { !isHiddenTestCell($0, hiddenTiers: hiddenTiers) }
    return (try? JSONSerialization.data(withJSONObject: nb)) ?? data
}

/// Merges a student's notebook with the instructor's canonical notebook.
///
/// Result cell list: student's non-test cells + all of the instructor's test cells.
///
/// This ensures the worker sees the student's solution code alongside all
/// authoritative test cells, including those stripped from the student download.
///
/// Returns `studentData` unchanged if either notebook fails to parse.
func mergeNotebook(student studentData: Data, instructor instructorData: Data) -> Data {
    guard var studentNB    = (try? JSONSerialization.jsonObject(with: studentData))    as? [String: Any],
          let instructorNB = (try? JSONSerialization.jsonObject(with: instructorData)) as? [String: Any],
          let studentCells    = studentNB["cells"]    as? [[String: Any]],
          let instructorCells = instructorNB["cells"] as? [[String: Any]]
    else { return studentData }

    let solutionCells = studentCells.filter   { !isTestCell($0) }
    let testCells     = instructorCells.filter {  isTestCell($0) }

    studentNB["cells"] = solutionCells + testCells
    return (try? JSONSerialization.data(withJSONObject: studentNB)) ?? studentData
}

/// Loads the notebook data for a test setup.
/// Prefers the flat `.ipynb` file (Phase 8 editable path); falls back to zip extraction.
func notebookData(for setup: APITestSetup) throws -> Data {
    if let path = setup.notebookPath,
       let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
       !data.isEmpty { return data }
    // Fall back to zip extraction.
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
    proc.arguments     = ["-p", setup.zipPath, "assignment.ipynb"]
    let pipe = Pipe()
    proc.standardOutput = pipe
    proc.standardError  = Pipe()    // discard stderr
    try proc.run()
    proc.waitUntilExit()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard proc.terminationStatus == 0, !data.isEmpty else {
        throw Abort(.notFound, reason: "No assignment.ipynb in this test setup")
    }
    return data
}

// MARK: - Route collection

struct TestSetupRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "testsetups")
        api.post(use: uploadTestSetup)
        api.group(":testSetupID") { group in
            group.get("download",                      use: downloadTestSetup)
            group.get("assignment",                    use: getAssignment)
            group.get("assignment", "download",        use: downloadAssignment)
            group.put("assignment",                    use: saveAssignment)
        }
    }

    // MARK: - POST /api/v1/testsetups  [instructor only]

    @Sendable
    func uploadTestSetup(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isInstructor else { throw Abort(.forbidden) }

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

    // MARK: - GET /api/v1/testsetups/:id/download  [instructor only]

    @Sendable
    func downloadTestSetup(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isInstructor else { throw Abort(.forbidden) }

        guard let setupID = req.parameters.get("testSetupID"),
              let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }
        return try await req.fileio.asyncStreamFile(at: setup.zipPath)
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment  [any authenticated user]

    @Sendable
    func getAssignment(req: Request) async throws -> Response {
        guard let setupID = req.parameters.get("testSetupID"),
              let setup   = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }

        let raw    = try notebookData(for: setup)
        let caller = req.auth.get(APIUser.self)
        let data   = (caller?.isInstructor == true)
            ? raw
            : filterNotebook(raw, hiddenTiers: hiddenTiersForStudents)

        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment/download  [any authenticated user]

    @Sendable
    func downloadAssignment(req: Request) async throws -> Response {
        guard let setupID = req.parameters.get("testSetupID"),
              let setup   = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }

        let raw      = try notebookData(for: setup)
        let filtered = filterNotebook(raw, hiddenTiers: hiddenTiersForStudents)

        // Determine a safe filename from the assignment title (if present).
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let title    = assignment?.title ?? setupID
        let safeName = title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        var headers = HTTPHeaders()
        headers.contentType = .json
        headers.add(name: .contentDisposition,
                    value: "attachment; filename=\"\(safeName).ipynb\"")
        return Response(status: .ok, headers: headers, body: .init(data: filtered))
    }

    // MARK: - PUT /api/v1/testsetups/:id/assignment  [instructor only, Phase 8]

    @Sendable
    func saveAssignment(req: Request) async throws -> HTTPStatus {
        let caller = try req.auth.require(APIUser.self)
        guard caller.isInstructor else { throw Abort(.forbidden) }

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
        let notebookBytes = Data(bodyBuffer.readableBytesView)

        // Basic JSON validation — reject obviously non-JSON bodies.
        guard (try? JSONSerialization.jsonObject(with: notebookBytes)) != nil else {
            throw Abort(.unprocessableEntity, reason: "Body is not valid JSON")
        }

        // Determine the save path: reuse existing notebookPath or derive from setupID.
        let notebookPath: String
        if let existing = setup.notebookPath {
            notebookPath = existing
        } else {
            notebookPath = req.application.testSetupsDirectory + "\(setupID).ipynb"
        }

        try notebookBytes.write(to: URL(fileURLWithPath: notebookPath))

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
