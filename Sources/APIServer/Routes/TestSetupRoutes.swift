// APIServer/Routes/TestSetupRoutes.swift
//
// Phase 2: test-setup management endpoints.
// Phase 9: notebook download endpoint (the pure notebook-JSON helpers live
// in Helpers/NotebookContentHelpers.swift as of #1119).
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

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Route collection

struct TestSetupRoutes: RouteCollection {
    func boot(routes: RoutesBuilder) throws {
        let api = routes.grouped("api", "v1", "testsetups")
        // Explicit cap sized to the zip-bomb guard (256 MB uncompressed,
        // TestSetupZipHelpers): the 10 MB global default rejected legitimate
        // dataset-heavy setups before validation ever ran (#1158).
        api.on(.POST, body: .collect(maxSize: "300mb"), use: uploadTestSetup)
        api.group(":testSetupID") { group in
            group.get("download", use: downloadTestSetup)
            group.get("assignment", use: getAssignment)
            group.get("assignment", "download", use: downloadAssignment)
            group.put("assignment", use: saveAssignment)
            group.get("support", ":filename", use: downloadSupportFile)
        }
    }

    // MARK: - POST /api/v1/testsetups  [instructor only]

    @Sendable
    func uploadTestSetup(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        let upload = try req.content.decode(TestSetupUpload.self)

        // Scope the create to the target course: only an instructor of that
        // course (and not an archived one) may upload a setup into it. Replaces
        // the old global `isInstructor` check, which trusted the client-supplied
        // `courseID` and let any global instructor create a setup — carrying
        // secret tests + solutions — in ANY course (#417 Slice D).
        try await requireCourseWriteAccess(caller: caller, courseID: upload.courseID, atLeast: .instructor, db: req.db)

        // Validate manifest JSON and schema version.
        let manifestData = Data(upload.manifest.utf8)
        let manifest: TestProperties
        do {
            manifest = try ManifestCodec.decoder.decode(TestProperties.self, from: manifestData)
        } catch {
            throw AppError.unprocessable(reason: "Invalid manifest JSON: \(error)")
        }
        guard manifest.schemaVersion == 1 else {
            throw AppError.unprocessable(reason: "Unsupported schemaVersion \(manifest.schemaVersion); expected 1")
        }

        // Validate the dependency graph (reference integrity + cycle detection).
        try validateManifestDependencies(manifest)

        // Mode-specific validation.
        switch manifest.gradingMode {
        case .browser:
            guard zipContainsNotebook(upload.files) else {
                throw AppError.unprocessable(
                    reason: "Browser-mode test setup must contain at least one .ipynb file")
            }
        case .worker:
            guard !manifest.testSuites.isEmpty else {
                throw AppError.unprocessable(reason: "Worker-mode test setup must contain at least one test suite")
            }
        }

        // Persist the zip.
        let setupsDir = req.application.testSetupsDirectory
        let setupID = "setup_\(UUID().uuidString.lowercased().prefix(8))"
        let zipPath = setupsDir + "\(setupID).zip"

        let zipBytes = upload.files
        try await req.fileio.writeFile(.init(data: zipBytes), at: zipPath)

        // Reject zip bombs before any DB row references this file.  The
        // upload sits in setupsDir until validation passes; on failure we
        // delete it so a malicious upload doesn't leave stale bytes on
        // disk indefinitely.  (Subprocess — thread pool, #1158.)
        do {
            try await runBlocking(on: req) { try validateZipUploadSize(zipPath: zipPath) }
        } catch let error as ZipUploadValidationError {
            try? FileManager.default.removeItem(atPath: zipPath)
            throw AppError.unprocessable(reason: String(describing: error))
        }

        // Store metadata in DB.
        let storedManifest =
            String(data: try ManifestCodec.encoder.encode(manifest), encoding: .utf8) ?? upload.manifest

        let setup = APITestSetup(
            id: setupID,
            manifest: storedManifest,
            zipPath: zipPath,
            courseID: upload.courseID
        )
        try await setup.save(on: req.db)

        // For browser-mode: extract and save the flat .ipynb file so the
        // instructor can edit it later without re-uploading the zip.
        if manifest.gradingMode == .browser {
            let notebookPath = setupsDir + "\(setupID).ipynb"
            if let data = try await runBlocking(on: req, { extractNotebookFromZip(zipPath: zipPath) }) {
                let normalized = normalizeNotebookForJupyterLite(data)
                try normalized.write(to: URL(fileURLWithPath: notebookPath))
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

        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // This streams the FULL setup zip — secret-tier test scripts and the
        // reference solution — so scope it to the setup's own course rather than
        // the old global `isInstructor` check, which let any instructor pull
        // another course's secret tests + solution by id. Instructor-level read
        // (admin bypass); the enrollment-gated student path is the separate
        // /browser-runner download (#417 Slice D). Sibling reads getAssignment /
        // downloadAssignment already scope via requireCourseEnrollment.
        try await requireCourseRole(
            caller: caller, courseID: setup.courseID, atLeast: .instructor, db: req.db)

        return try await req.fileio.asyncStreamFile(at: setup.zipPath)
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment  [enrolled students + instructors]

    @Sendable
    func getAssignment(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        // Cached, single-flighted, resolved on the thread pool (#1156/#1171).
        let raw = try await req.application.notebookBytesCache.notebookData(
            for: NotebookSourceRef(setup))
        // Staff (TA+ or admin) of this setup's course see unfiltered tiers;
        // students get the hidden tiers stripped (#417 Slice G).
        let isStaff = try await isCourseStaff(caller, inCourse: setup.courseID, db: req.db)
        let data =
            isStaff
            ? raw
            : filterNotebook(raw, hiddenTiers: hiddenTiersForStudents)

        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data)
        )
    }

    // MARK: - GET /api/v1/testsetups/:id/assignment/download  [enrolled students + instructors]

    @Sendable
    func downloadAssignment(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        // Cached, single-flighted, resolved on the thread pool (#1156/#1171).
        let raw = try await req.application.notebookBytesCache.notebookData(
            for: NotebookSourceRef(setup))
        let isStaff = try await isCourseStaff(caller, inCourse: setup.courseID, db: req.db)
        let filtered = isStaff ? raw : filterNotebook(raw, hiddenTiers: hiddenTiersForStudents)

        // Determine a safe filename from the assignment title (if present).
        let assignment = try await APIAssignment.query(on: req.db)
            .filter(\.$testSetupID == setupID)
            .first()
        let title = assignment?.title ?? setupID
        let safeName =
            title
            .components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|"))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)

        var headers = HTTPHeaders()
        headers.contentType = .json
        headers.add(
            name: .contentDisposition,
            value: "attachment; filename=\"\(safeName).ipynb\"")
        return Response(status: .ok, headers: headers, body: .init(data: filtered))
    }

    // MARK: - GET /api/v1/testsetups/:id/support/:filename  [enrolled students + instructors]
    //
    // Streams a single support file (CSV / JSON / etc.) from the test
    // setup zip to the caller.  Same enrolled-student gate as the
    // assignment-download route.  Refuses to stream test scripts and
    // notebooks — only files classified as `tier == "support"` (i.e.
    // not in `testSuites` and not the canonical notebook names).
    // v0.4.117+: enables students to download data fixtures for offline
    // work; the same files are already symlinked into their JupyterLite
    // working dir for in-browser editing.

    @Sendable
    func downloadSupportFile(req: Request) async throws -> Response {
        let caller = try req.auth.require(APIUser.self)
        guard let setupID = req.parameters.get("testSetupID"),
            let filename = req.parameters.get("filename"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else { throw Abort(.notFound) }

        try await requireCourseEnrollment(caller: caller, courseID: setup.courseID, db: req.db)

        // Refuse path-traversal-shaped filenames outright.  Names with
        // slashes, backslashes, or `..` segments are never produced by
        // legitimate uploads.
        guard !filename.isEmpty,
            !filename.contains("/"), !filename.contains("\\"),
            !filename.contains("..")
        else {
            throw AppError.invalidParameter(
                name: "filename", reason: "must not contain path separators or empty segments")
        }

        // Confirm the file is classified as a support file: must exist
        // in the zip, must not be in `testSuites`, must not be a
        // canonical notebook name. Cached (#1156) — this previously spawned
        // a serialized `unzip` subprocess on the request thread per download.
        let allEntries = await req.application.zipEntryListCache.entries(zipPath: setup.zipPath)
        guard allEntries.contains(filename) else { throw Abort(.notFound) }

        let props = setup.decodedManifest()
        let testScripts = Set(props?.testSuites.map(\.script) ?? [])
        // Grader-only files (answer keys, reserved holdout sets) are bundled for
        // the worker but never served to students — block them here alongside
        // test scripts and the canonical notebooks. See docs/datasets.md.
        let graderOnly = props?.graderOnlyFileSet ?? []
        let reservedNames: Set<String> = ["assignment.ipynb", "solution.ipynb"]
        guard !testScripts.contains(filename), !reservedNames.contains(filename),
            !graderOnly.contains(filename)
        else {
            throw AppError.forbidden(action: "download '\(filename)' (not a student-visible support file)")
        }

        let zipPath = setup.zipPath
        let extracted = try await runBlocking(on: req) {
            extractZipEntry(zipPath: zipPath, entryName: filename)
        }
        guard let bytes = extracted else {
            throw Abort(.notFound)
        }

        var headers = HTTPHeaders()
        headers.contentType =
            HTTPMediaType.fileExtension(
                (filename as NSString).pathExtension.lowercased()
            ) ?? .binary
        headers.add(
            name: .contentDisposition,
            value: "attachment; filename=\"\(filename)\"")
        return Response(status: .ok, headers: headers, body: .init(data: bytes))
    }

    // MARK: - PUT /api/v1/testsetups/:id/assignment  [instructor only, Phase 8]

    @Sendable
    func saveAssignment(req: Request) async throws -> HTTPStatus {
        let caller = try req.auth.require(APIUser.self)

        guard let setupID = req.parameters.get("testSetupID"),
            let setup = try await APITestSetup.find(setupID, on: req.db)
        else {
            throw Abort(.notFound)
        }

        // Overwriting the setup's notebook on disk is a per-course write: scope
        // it to the setup's own course (and block archived). Replaces the old
        // global `isInstructor` check, which let any global instructor overwrite
        // any course's notebook by :testSetupID (#417 Slice D).
        try await requireCourseWriteAccess(caller: caller, courseID: setup.courseID, atLeast: .instructor, db: req.db)

        // Collect the raw request body as Data.
        guard let bodyBuffer = req.body.data,
            bodyBuffer.readableBytes > 0
        else {
            throw AppError.badRequest(reason: "Request body is empty")
        }
        let notebookBytes = Data(bodyBuffer.readableBytesView)

        // Basic JSON validation — reject obviously non-JSON bodies.
        guard (try? JSONSerialization.jsonObject(with: notebookBytes)) != nil else {
            throw AppError.unprocessable(reason: "Body is not valid JSON")
        }

        // Determine the save path: reuse existing notebookPath or derive from setupID.
        let notebookPath: String
        if let existing = setup.notebookPath {
            notebookPath = existing
        } else {
            notebookPath = req.application.testSetupsDirectory + "\(setupID).ipynb"
        }

        let normalizedNotebook = normalizeNotebookForJupyterLite(notebookBytes)
        try normalizedNotebook.write(to: URL(fileURLWithPath: notebookPath))

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
    /// UUID of the course this test setup belongs to.
    var courseID: UUID
}
