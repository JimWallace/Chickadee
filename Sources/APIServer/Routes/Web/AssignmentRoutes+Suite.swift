// APIServer/Routes/Web/AssignmentRoutes+Suite.swift
//
// The unified suite-editor endpoint.  GET returns the full reconciled
// author-facing view of the suite list (scripts + families, in manifest
// order, with `family:<id>` tokens re-collapsed in the `dependsOn` field).
// PUT replaces the whole list atomically by delegating to
// `applyPatternFamilies`, which handles validation, zip mutation, and
// manifest rewrite.

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    // MARK: - DTOs

    /// One row in the unified suite list, in either direction (GET response
    /// or PUT request body).  Array order is authoritative for UI order.
    struct SuiteItemDTO: Content {
        /// "script" or "family".
        var kind: String
        /// Present when kind == "script".
        var script: ScriptDTO?
        /// Present when kind == "family".
        var family: PatternFamily?
        /// Present when kind == "family".  Family-level deps live on the
        /// family spec too, but we echo them here at the row level for
        /// editor-UI convenience.
        var dependsOn: [String]?
    }

    struct ScriptDTO: Content {
        var script: String               // filename
        var tier: TestTier
        var points: Int
        var displayName: String?
        var dependsOn: [String]          // may contain "family:<id>" tokens
    }

    struct SuitePayload: Content {
        var items: [SuiteItemDTO]
    }

    // MARK: - GET /instructor/:assignmentID/suite

    /// Reconstitutes the author-facing suite items list from the current
    /// persisted manifest.  For each family, collapses `dependsOn` arrays
    /// elsewhere in the manifest that happen to be exactly the family's
    /// enabled-case filename set back into a single `family:<id>` token, so
    /// the editor UI sees the author's high-level intent rather than the
    /// runner-facing expanded form.
    @Sendable
    func getSuite(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

    // MARK: - PUT /instructor/:assignmentID/suite

    /// Replaces the full suite list in one atomic operation.  The server
    /// validates + expands + persists via `applyPatternFamilies`, then
    /// returns the reconciled state so the client can replace its local
    /// view without a second round-trip.
    @Sendable
    func putSuite(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        let body: SuitePayload
        do { body = try req.content.decode(SuitePayload.self) }
        catch {
            throw Abort(.badRequest,
                reason: "Invalid suite payload: \(error.localizedDescription)")
        }

        // Translate the DTO into the AuthoredSuiteItem model.
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
                // Allow callers to carry the family's top-level dependsOn in
                // either `family.dependsOn` or `item.dependsOn`; the row-
                // level field wins so the UI can adopt a dep without
                // rebuilding the whole family spec.
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

        let payload = buildSuitePayload(fromManifest: setup.manifest)
        return try await payload.encodeResponse(for: req)
    }

}

// MARK: - Reconstitution (file-scope so other routes can reuse it)

/// Reads a persisted manifest and builds the author-facing view of the
/// suite list, collapsing fully-expanded family filename sets back into
/// `family:<id>` tokens so the editor sees intent, not plumbing.
func buildSuitePayload(fromManifest manifest: String) -> AssignmentRoutes.SuitePayload {
    guard let data = manifest.data(using: .utf8),
          let props = try? JSONDecoder().decode(TestProperties.self, from: data) else {
        return AssignmentRoutes.SuitePayload(items: [])
    }

    let familyByID = Dictionary(uniqueKeysWithValues: props.patternFamilies.map { ($0.id, $0) })
    var familyFilenames: [String: Set<String>] = [:]
    for f in props.patternFamilies {
        familyFilenames[f.id] = Set(f.cases
            .filter(\.enabled)
            .map { c in
                generatedScriptFilename(
                    familyID: f.id,
                    caseKey: c.key,
                    tier: c.resolvedTier(defaults: f.defaults)
                )
            })
    }

    // Collapse expanded family-filename subsets back into family: tokens.
    func collapseDeps(_ deps: [String]) -> [String] {
        var remaining = deps
        var collapsed: [String] = []
        for (fid, filenames) in familyFilenames {
            if !filenames.isEmpty,
               Set(remaining).isSuperset(of: filenames) {
                remaining.removeAll { filenames.contains($0) }
                collapsed.append(familyDepToken(fid))
            }
        }
        return remaining + collapsed
    }

    // Walk testSuites in order, emitting one item per script or, on the
    // first generated entry for a family, one family row.  Family rows'
    // `dependsOn` comes from the PatternFamily spec (already in author
    // form) rather than from the expanded per-case entries.
    var items: [AssignmentRoutes.SuiteItemDTO] = []
    var emittedFamilyIDs: Set<String> = []
    for entry in props.testSuites {
        if let fid = entry.generatedBy {
            guard !emittedFamilyIDs.contains(fid), let family = familyByID[fid] else { continue }
            emittedFamilyIDs.insert(fid)
            items.append(AssignmentRoutes.SuiteItemDTO(
                kind: "family",
                script: nil,
                family: family,
                dependsOn: family.dependsOn
            ))
        } else {
            items.append(AssignmentRoutes.SuiteItemDTO(
                kind: "script",
                script: AssignmentRoutes.ScriptDTO(
                    script:      entry.script,
                    tier:        entry.tier,
                    points:      entry.points,
                    displayName: entry.name,
                    dependsOn:   collapseDeps(entry.dependsOn)
                ),
                family: nil,
                dependsOn: nil
            ))
        }
    }

    return AssignmentRoutes.SuitePayload(items: items)
}

/// Convenience: full `GET /suite` payload as sorted-keys JSON string.
func suiteStateJSON(fromManifest manifest: String) -> String {
    let payload = buildSuitePayload(fromManifest: manifest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(payload),
          let s = String(data: data, encoding: .utf8)
    else { return #"{"items":[]}"# }
    return s
}
