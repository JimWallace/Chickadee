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
// refactor.  The shared helpers (`applyPatternFamilies`,
// `buildSuitePayload`, `listZipEntries`, …) already operate on
// `APITestSetup`, so these are thin wrappers.
//
// Routes:
//   GET    /instructor/new/draft/suite?draftID=<id>
//   PUT    /instructor/new/draft/suite?draftID=<id>
//   PUT    /instructor/new/draft/families?draftID=<id>
//   POST   /instructor/new/draft/scripts?draftID=<id>
//   DELETE /instructor/new/draft/scripts/:filename?draftID=<id>

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    // MARK: - Helpers

    /// Resolves the draft `APITestSetup` from a `draftID` query parameter.
    /// Throws `400` if missing, `404` if not found.
    private func draftSetupFromQuery(_ req: Request) async throws -> APITestSetup {
        guard let draftID = try? req.query.get(String.self, at: "draftID"),
              !draftID.isEmpty else {
            throw Abort(.badRequest, reason: "Missing `draftID` query parameter")
        }
        guard let setup = try await APITestSetup.find(draftID, on: req.db) else {
            throw Abort(.notFound, reason: "Draft '\(draftID)' not found")
        }
        return setup
    }

    // MARK: - GET /instructor/new/draft/suite

    @Sendable
    func getDraftSuite(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let setup = try await draftSetupFromQuery(req)
        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/new/draft/suite

    @Sendable
    func putDraftSuite(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let setup = try await draftSetupFromQuery(req)

        let body: SuitePayload
        do { body = try req.content.decode(SuitePayload.self) }
        catch {
            throw Abort(.badRequest,
                reason: "Invalid suite payload: \(error.localizedDescription)")
        }

        var authored: [AuthoredSuiteItem] = []
        var nextFamilies: [PatternFamily] = []
        for item in body.items {
            switch item.kind {
            case "script":
                guard let s = item.script else {
                    throw Abort(.badRequest,
                        reason: "Suite item kind=script is missing `script` payload.")
                }
                authored.append(.script(AuthoredRawScript(
                    script: s.script,
                    tier: s.tier,
                    points: s.points,
                    displayName: s.displayName,
                    dependsOn: s.dependsOn
                )))
            case "family":
                guard var f = item.family else {
                    throw Abort(.badRequest,
                        reason: "Suite item kind=family is missing `family` payload.")
                }
                if let rowDeps = item.dependsOn {
                    f = PatternFamily(
                        id: f.id, name: f.name, kind: f.kind,
                        functionName: f.functionName, paramNames: f.paramNames,
                        defaults: f.defaults, cases: f.cases,
                        dependsOn: rowDeps
                    )
                }
                authored.append(.family(id: f.id))
                nextFamilies.append(f)
            default:
                throw Abort(.badRequest,
                    reason: "Unknown suite item kind '\(item.kind)'.")
            }
        }

        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: nextFamilies,
            authoredItems: authored,
            on: req.db
        )

        // Drafts don't have a validation pipeline yet — that kicks in on
        // publish.  Skip the scheduleValidationAfterSuiteEdit call the
        // assignment-scoped handler makes.

        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/new/draft/families

    @Sendable
    func putDraftPatternFamilies(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let setup = try await draftSetupFromQuery(req)

        let families: [PatternFamily]
        do {
            families = try req.content.decode([PatternFamily].self)
        } catch {
            throw Abort(.badRequest,
                reason: "Invalid pattern family list: \(error.localizedDescription)")
        }

        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: families,
            on: req.db
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(families)
        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: data))
    }

    // MARK: - POST /instructor/new/draft/scripts

    @Sendable
    func createDraftScript(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let setup = try await draftSetupFromQuery(req)

        struct CreateBody: Content {
            var filename: String
            var content:  String
            var tier:     String?
            var points:   Int?
            var isTest:   Bool?
        }
        let body = try req.content.decode(CreateBody.self)

        let cleaned = sanitizeSuiteFilename(body.filename)
        guard !cleaned.isEmpty, cleaned == body.filename else {
            throw Abort(.badRequest, reason: "Invalid filename '\(body.filename)'")
        }

        if listZipEntries(zipPath: setup.zipPath).contains(cleaned) {
            throw Abort(.conflict, reason: "A file named '\(cleaned)' already exists in this setup")
        }

        try updateScriptInZip(zipPath: setup.zipPath, filename: cleaned, content: body.content)

        let tier       = normalizeTier(body.tier, isTest: body.isTest)
        // v0.4.105: allow 0-mark tests for guards (see AssignmentRoutes+Editor).
        let points     = max(0, body.points ?? 1)
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
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let setup    = try await draftSetupFromQuery(req)
        let filename = try safeScriptFilename(from: req)

        guard listZipEntries(zipPath: setup.zipPath).contains(filename) else {
            throw Abort(.notFound, reason: "File '\(filename)' not found in setup zip")
        }

        if let familyID = generatedByFamilyID(manifestJSON: setup.manifest, filename: filename) {
            throw Abort(.conflict,
                reason: "'\(filename)' is generated from pattern family '\(familyID)'. Remove it via the family editor.")
        }

        let dependents = manifestDependents(manifestJSON: setup.manifest, filename: filename)
        guard dependents.isEmpty else {
            throw Abort(.conflict,
                reason: "Cannot delete '\(filename)': the following scripts depend on it: \(dependents.joined(separator: ", "))")
        }

        do {
            try removeScriptFromZip(zipPath: setup.zipPath, filename: filename)
        } catch ScriptZipError.zipFailed {
            throw Abort(.internalServerError, reason: "Failed to update setup zip")
        }

        if let updated = updateManifestRemovingScript(manifestJSON: setup.manifest, filename: filename) {
            setup.manifest = updated
            try await setup.save(on: req.db)
        }
        return .noContent
    }
}
