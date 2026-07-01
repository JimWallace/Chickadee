// APIServer/Routes/Web/PublishedAssignmentRoutes+ScriptCRUD.swift
//
// Inline CRUD for individual test/support files inside the test
// setup zip:
//   GET    /instructor/:assignmentID/scripts/:filename
//   PUT    /instructor/:assignmentID/scripts/:filename
//   POST   /instructor/:assignmentID/scripts
//   DELETE /instructor/:assignmentID/scripts/:filename
//
// Split out of `AssignmentRoutes+Editor.swift` in v0.4.183 (Phase 4.2
// of the audit-driven refactor).  No behaviour change.  The
// `safeScriptFilename(from:)` helper at the bottom is shared with
// `AssignmentRoutes+Draft.swift`'s draft-scoped delete handler.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {
    // MARK: - GET /instructor/:assignmentID/scripts/:filename
    //
    // Returns the raw text content of a single file from the setup zip.

    @Sendable
    func getScript(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetupForStaffRead(req)
        let filename = try safeScriptFilename(from: req)

        guard let content = readScriptFromZip(zipPath: setup.zipPath, filename: filename) else {
            throw WebAssignmentError.notFound(resource: "File '\(filename)' in setup zip")
        }
        var headers = HTTPHeaders()
        headers.contentType = .plainText
        return Response(status: .ok, headers: headers, body: .init(string: content))
    }

    // MARK: - PUT /instructor/:assignmentID/scripts/:filename
    //
    // Replaces the content of an existing script in the setup zip.
    // Body (JSON): { "content": "..." }

    @Sendable
    func updateScript(req: Request) async throws -> HTTPStatus {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req)
        let filename = try safeScriptFilename(from: req)

        struct UpdateBody: Content { var content: String }
        let body = try req.content.decode(UpdateBody.self)

        // Verify the file exists before writing.
        guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
            throw WebAssignmentError.notFound(resource: "File '\(filename)' in setup zip")
        }

        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
            throw WebAssignmentError.conflict(
                reason:
                    "'\(filename)' is generated from pattern family '\(familyID)'. Edit the family rather than the generated script."
            )
        }

        // Slice 1: inline global + section variables before write so the
        // saved script content matches what the runner will see.  Falls
        // back to raw content for non-.py files or when manifest decode
        // fails (degrades to pre-Slice-1 behaviour).
        let inlinedContent: String = {
            guard let manifest = setup.decodedManifest()

            else { return body.content }
            return TestScriptVariablePrepender.applyForRawScript(
                filename: filename,
                content: body.content,
                manifest: manifest
            )
        }()

        do {
            try updateScriptInZip(zipPath: setup.zipPath, filename: filename, content: inlinedContent)
        } catch ScriptZipError.zipFailed {
            throw WebAssignmentError.internalFailure(reason: "Failed to update setup zip")
        }
        return .noContent
    }

    // MARK: - POST /instructor/:assignmentID/scripts
    //
    // Creates a new script file in the setup zip and adds a TestSuiteEntry
    // to the manifest (default: public tier, 1 point, no dependencies).
    // Body (JSON): { "filename": "test_new.py", "content": "...", "tier": "public", "points": 1 }

    @Sendable
    func createScript(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req)
        let idStr = assignment.publicID
        let body = try req.content.decode(CreateScriptBody.self)

        let result = try await createScriptInSetup(setup: setup, body: body, on: req.db)

        if !result.isTest {
            // Support files (tier=="support") aren't entries in `testSuites`,
            // but they still need to land in the shared extraction dir so
            // student JupyterLite working copies pick them up via the symlinks
            // created in `createSupportFileSymlinks`. v0.4.116+: keep the
            // shared dir in sync after every POST /scripts upload, not just
            // the bigger /edit/save flow.
            let activeTestSuiteScripts: Set<String> = {
                guard let props = setup.decodedManifest() else { return [] }
                return Set(props.testSuites.map(\.script))
            }()
            extractSupportFilesToSharedDirectory(
                zipPath: setup.zipPath,
                setupID: assignment.testSetupID,
                testSuiteScripts: activeTestSuiteScripts,
                testSetupsDirectory: req.application.testSetupsDirectory
            )
        }

        struct CreatedResponse: Content {
            var filename: String
            var tier: String
            var points: Int
            var isTest: Bool
            var editURL: String
        }
        let resp = CreatedResponse(
            filename: result.filename,
            tier: result.tier,
            points: result.points,
            isTest: result.isTest,
            editURL: "/instructor/\(idStr)/scripts/\(urlEncode(result.filename))"
        )
        return try await resp.encodeResponse(status: .created, for: req)
    }

    // MARK: - DELETE /instructor/:assignmentID/scripts/:filename
    //
    // Removes a script from the setup zip and manifest.
    // Returns 409 if other scripts in the manifest depend on this one.

    @Sendable
    func deleteScript(req: Request) async throws -> HTTPStatus {
        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req)
        let filename = try safeScriptFilename(from: req)

        try await deleteScriptFromSetup(setup: setup, filename: filename, on: req.db)

        // Re-extract support files to the shared dir (parallels the
        // create-script path).  Idempotent and cheap; the shared dir
        // is just a flat extraction of every non-test, non-notebook
        // entry in the zip, so a deleted file vanishes from there too.
        let activeTestSuiteScripts: Set<String> = {
            guard let props = setup.decodedManifest()

            else { return [] }
            return Set(props.testSuites.map(\.script))
        }()
        extractSupportFilesToSharedDirectory(
            zipPath: setup.zipPath,
            setupID: assignment.testSetupID,
            testSuiteScripts: activeTestSuiteScripts,
            testSetupsDirectory: req.application.testSetupsDirectory
        )
        return .noContent
    }
}

// MARK: - Route parameter helpers

/// Extracts and validates the `:filename` route parameter.
/// Rejects any value that contains path separators or traversal components.
/// File-internal (not private) so AssignmentRoutes+Draft.swift can reuse
/// the same sanitisation for its draft-scoped `delete` handler.
func safeScriptFilename(from req: Request) throws -> String {
    guard let raw = req.parameters.get("filename"), !raw.isEmpty else {
        throw WebAssignmentError.invalidParameter(name: "filename", reason: "Missing filename parameter")
    }
    let cleaned = (raw as NSString).lastPathComponent
    guard cleaned == raw, !cleaned.isEmpty, cleaned != ".", cleaned != ".." else {
        throw WebAssignmentError.invalidParameter(name: "filename", reason: "Invalid filename '\(raw)'")
    }
    return cleaned
}
