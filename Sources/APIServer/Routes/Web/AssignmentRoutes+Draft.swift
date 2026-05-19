// APIServer/Routes/Web/AssignmentRoutes+Draft.swift
//
// Draft-scoped siblings of the pattern-family / suite / script endpoints.
// The Create Assignment page (`/instructor/new`) operates on an
// in-progress `APITestSetup` identified by a `draftID` query parameter
// BEFORE the assignment is published.  These handlers mirror the
// `:assignmentID`-scoped endpoints but resolve the target setup directly
// by draftID, skipping the `APIAssignment` lookup (there isn't one yet).
//
// Added in v0.4.91 as phase 2 of the Create/Edit authoring-page parity
// refactor.  v0.4.131 collapsed each handler down to a draft-target
// resolution + shared core call by extracting `applySuiteEdit`,
// `applyPatternFamiliesEdit`, and the auth/load helpers into
// `SuiteEditHelpers.swift`; pre-fix this file duplicated the DTO
// translation, manifest-encoding, and JSON response boilerplate from
// `AssignmentRoutes+Suite.swift` and `AssignmentRoutes+Families.swift`.
//
// Routes:
//   GET    /instructor/new/draft/suite?draftID=<id>
//   PUT    /instructor/new/draft/suite?draftID=<id>
//   PUT    /instructor/new/draft/families?draftID=<id>
//   POST   /instructor/new/draft/scripts?draftID=<id>
//   DELETE /instructor/new/draft/scripts/:filename?draftID=<id>

import Core
import Fluent
import Foundation
import Vapor

extension DraftAssignmentRoutes {

    // MARK: - GET /instructor/new/draft/suite

    @Sendable
    func getDraftSuite(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)
        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/new/draft/suite
    //
    // Drafts don't have a validation pipeline yet — that kicks in on
    // publish.  So this is the bare apply-edit + return-reconciled
    // pattern; no `scheduleValidationAfterSuiteEdit` call.

    @Sendable
    func putDraftSuite(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)

        let body: SuitePayload
        do { body = try req.content.decode(SuitePayload.self) } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid suite payload: \(error.localizedDescription)")
        }

        try await applySuiteEdit(setup: setup, body: body, on: req.db)

        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/new/draft/families

    @Sendable
    func putDraftPatternFamilies(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)

        let families: [PatternFamily]
        do {
            families = try req.content.decode([PatternFamily].self)
        } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid pattern family list: \(error.localizedDescription)")
        }

        try await applyPatternFamiliesEdit(setup: setup, families: families, on: req.db)

        return try jsonResponse(families)
    }

    // MARK: - PUT /instructor/new/draft/checks
    //
    // Draft-scoped sibling of `putNotebookChecks` (parity PR 2 of #433).
    // Same body / response shape; the only differences are the resolver
    // (`loadDraftSetup` reading `?draftID=…`) and the absence of the
    // `scheduleValidationAfterSuiteEdit` call — drafts don't enter the
    // validation pipeline until publish.

    @Sendable
    func putDraftNotebookChecks(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)

        let checks: [NotebookCheck]
        do {
            checks = try req.content.decode([NotebookCheck].self)
        } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid notebook check list: \(error.localizedDescription)")
        }

        try await applyNotebookChecksEdit(setup: setup, checks: checks, on: req.db)

        return try jsonResponse(checks)
    }

    // MARK: - POST /instructor/new/draft/scripts

    @Sendable
    func createDraftScript(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)

        struct CreateBody: Content {
            var filename: String
            var content: String
            var tier: String?
            var points: Int?
            var isTest: Bool?
        }
        let body = try req.content.decode(CreateBody.self)

        let cleaned = sanitizeSuiteFilename(body.filename)
        guard !cleaned.isEmpty, cleaned == body.filename else {
            throw WebAssignmentError.invalidParameter(name: "filename", reason: "Invalid filename '\(body.filename)'")
        }

        if listZipEntries(zipPath: setup.zipPath).contains(cleaned) {
            throw WebAssignmentError.conflict(reason: "A file named '\(cleaned)' already exists in this setup")
        }

        // Slice 1: prepend assignment-scope variables (section vars get
        // applied on the next suite-edit save once the new entry's
        // sectionID is known).
        let inlinedContent: String = {
            guard let data = setup.manifest.data(using: .utf8),
                let manifest = try? ManifestCodec.decoder.decode(TestProperties.self, from: data)
            else { return body.content }
            return TestScriptVariablePrepender.applyForRawScript(
                filename: cleaned,
                content: body.content,
                manifest: manifest
            )
        }()
        try updateScriptInZip(zipPath: setup.zipPath, filename: cleaned, content: inlinedContent)

        let tier = normalizeTier(body.tier, isTest: body.isTest)
        // v0.4.105: allow 0-mark tests for guards (see AssignmentRoutes+Editor).
        let points = max(0, body.points ?? 1)
        let shouldTest = tier != "support"

        if shouldTest {
            let entry = ConfiguredSuiteEntry(
                script: cleaned, tier: tier, order: 0,
                dependsOn: [], points: points, displayName: nil
            )
            if let updated = updateManifestAddingScript(manifestJSON: setup.manifest, entry: entry) {
                setup.manifest = updated
                try await setup.save(on: req.db)
            }
        }

        struct CreatedResponse: Content {
            var filename: String
            var tier: String
            var points: Int
            var isTest: Bool
        }
        // Note: no editURL yet — the draft doesn't have a stable assignment
        // route.  The create page re-renders with the updated suite state
        // to pick up the new row.
        let resp = CreatedResponse(
            filename: cleaned,
            tier: tier,
            points: points,
            isTest: shouldTest
        )
        return try await resp.encodeResponse(status: .created, for: req)
    }

    // MARK: - DELETE /instructor/new/draft/scripts/:filename

    @Sendable
    func deleteDraftScript(req: Request) async throws -> HTTPStatus {
        let setup = try await loadDraftSetup(req)
        let filename = try safeScriptFilename(from: req)

        guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
            throw WebAssignmentError.notFound(resource: "File '\(filename)' in setup zip")
        }

        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
            throw WebAssignmentError.conflict(
                reason: "'\(filename)' is generated from pattern family '\(familyID)'. Remove it via the family editor."
            )
        }

        let dependents = manifestDependents(manifestJSON: setup.manifest, filename: filename)
        guard dependents.isEmpty else {
            throw WebAssignmentError.conflict(
                reason:
                    "Cannot delete '\(filename)': the following scripts depend on it: \(dependents.joined(separator: ", "))"
            )
        }

        do {
            try removeScriptFromZip(zipPath: setup.zipPath, filename: filename)
        } catch ScriptZipError.zipFailed {
            throw WebAssignmentError.internalFailure(reason: "Failed to update setup zip")
        }

        if let updated = updateManifestRemovingScript(manifestJSON: setup.manifest, filename: filename) {
            setup.manifest = updated
            try await setup.save(on: req.db)
        }
        return .noContent
    }

    // MARK: - GET /instructor/new/draft/files/item?draftID=<id>&name=<filename>
    //
    // Draft-scoped sibling of `downloadCurrentSetupItem` (the assignment-
    // scoped download).  Used by the support-files list on the create
    // page so the instructor can click a filename to download / inspect
    // the file before publish.  Same lookup-by-name pattern; no path
    // traversal allowed (lastPathComponent guard).

    @Sendable
    func downloadDraftSetupItem(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)

        struct FileQuery: Content { let name: String }
        let q = try req.query.decode(FileQuery.self)
        let fileName = (q.name as NSString).lastPathComponent
        guard !fileName.isEmpty, fileName == q.name else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Invalid file name")
        }

        guard let data = extractZipEntry(zipPath: setup.zipPath, entryName: fileName) else {
            throw WebAssignmentError.notFound(resource: "File '\(fileName)' in setup")
        }
        return buildFileResponse(data: data, filename: fileName)
    }

    // MARK: - GET /instructor/new/draft/solution-notebook
    //
    // Returns the draft solution notebook JSON so the scan-for-functions flow
    // works after an upload round-trip (file input is empty on reload).
    // Moved from `AssignmentRoutes+Editor.swift` in v0.4.177 because the
    // route is draft-scoped and the handler now lives on
    // `DraftAssignmentRoutes`.

    @Sendable
    func draftSolutionNotebook(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let userID = user.id else {
            throw WebAssignmentError.internalFailure(reason: "Authenticated user has no ID")
        }

        guard let draftID = try? req.query.get(String.self, at: "draftID"),
            !draftID.isEmpty,
            try await APITestSetup.find(draftID, on: req.db) != nil
        else { throw WebAssignmentError.notFound(resource: "Draft assignment") }

        // setup.id equals draftID (lookup key); use the query parameter
        // directly so we don't have to force-unwrap setup.id.
        let fallbackPath = draftSolutionNotebookPath(
            testSetupsDirectory: req.application.testSetupsDirectory, setupID: draftID)
        guard
            let data = draftNotebookData(
                req: req, setupID: draftID, userID: userID,
                fileKind: .solution, fallbackPath: fallbackPath)
        else { throw WebAssignmentError.notFound(resource: "Draft solution notebook") }

        return Response(
            status: .ok,
            headers: ["Content-Type": "application/json"],
            body: .init(data: data))
    }
}
