// APIServer/Routes/Web/SuiteEditHelpers.swift
//
// Shared core for the Suite / Families / Checks / Suite Sections handlers
// — both the assignment-scoped variants (`/instructor/:assignmentID/...`)
// and the draft-scoped variants used by the create page
// (`/instructor/new/draft/...?draftID=<id>`).  Pre-v0.4.131 each pair of
// endpoints (assignment vs draft) duplicated:
//
//   1. auth + role check
//   2. setup resolution
//   3. body decoding + DTO translation
//   4. call into `applyPatternFamilies` with the appropriate next-state
//   5. (assignment-only) `scheduleValidationAfterSuiteEdit`
//
// That duplication kept feature parity between the two pages a chore —
// e.g. v0.4.96 sections, v0.4.113-118 notebook checks, and v0.4.114
// support files all landed on the assignment-scoped side and have not
// yet been wired into the create page.  Consolidating the apply cores
// here makes adding a missing draft endpoint a few lines of routing
// rather than a duplicate handler.
//
// Approach: shared pure functions, not a new enum or protocol.  Each
// thin handler still reads as a complete unit; the shared core takes a
// raw `APITestSetup` (already the unit applyPatternFamilies operates on)
// plus the decoded body, returns the reconciled state, and trusts the
// caller to deal with target-specific concerns (validation scheduling,
// redirect targets).

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Setup resolution

/// Loads the (assignment, setup) pair from a `:assignmentID` path
/// parameter.  Throws `.notFound` if either the assignment or its
/// referenced test setup is missing.
func loadAssignmentAndSetup(_ req: Request) async throws -> (APIAssignment, APITestSetup) {
    let idStr = try assignmentPublicIDParameter(from: req)
    guard
        let assignment = try await assignmentByPublicID(idStr, on: req.db),
        let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
    else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }
    return (assignment, setup)
}

/// Loads a draft test setup from the `?draftID=<id>` query parameter.
/// The draft model is just an `APITestSetup` row that hasn't been
/// linked to an `APIAssignment` yet — same row shape, no parent.
/// Throws `.badRequest` if the parameter is missing/empty,
/// `.notFound` if no row matches.
func loadDraftSetup(_ req: Request) async throws -> APITestSetup {
    guard let draftID = try? req.query.get(String.self, at: "draftID"),
        !draftID.isEmpty
    else {
        throw WebAssignmentError.invalidParameter(name: "draftID", reason: "Missing `draftID` query parameter")
    }
    guard let setup = try await APITestSetup.find(draftID, on: req.db) else {
        throw WebAssignmentError.notFound(resource: "Draft '\(draftID)'")
    }
    return setup
}

// MARK: - Suite-list editor core

/// Translates a `SuitePayload` into `applyPatternFamilies` arguments and
/// applies it.  Used by both `PUT /instructor/:id/suite` and
/// `PUT /instructor/new/draft/suite`.
///
/// Errors:
///   - `.badRequest` for malformed items (missing script payload, missing
///     family payload, unknown kind).
///   - whatever `applyPatternFamilies` throws for validation failures.
func applySuiteEdit(
    setup: APITestSetup,
    body: SuitePayload,
    on db: Database
) async throws {
    var authored: [AuthoredSuiteItem] = []
    var nextFamilies: [PatternFamily] = []
    var nextChecks: [NotebookCheck] = []
    for item in body.items {
        switch item.kind {
        case "script":
            guard let s = item.script else {
                throw WebAssignmentError.invalidParameter(
                    name: "items",
                    reason: "Suite item kind=script is missing `script` payload.")
            }
            authored.append(
                .script(
                    AuthoredRawScript(
                        script: s.script,
                        tier: s.tier,
                        points: s.points,
                        displayName: s.displayName,
                        dependsOn: s.dependsOn,
                        sectionID: item.sectionID,
                        content: s.content
                    )))
        case "family":
            guard var f = item.family else {
                throw WebAssignmentError.invalidParameter(
                    name: "items",
                    reason: "Suite item kind=family is missing `family` payload.")
            }
            // Allow callers to carry the family's top-level dependsOn in
            // either `family.dependsOn` or `item.dependsOn`; the row-level
            // field wins so the UI can adopt a dep without rebuilding the
            // whole family spec.  Preserves `variables` (added in v0.4.94)
            // — without that an `argVarRefs` reference would fail
            // validation on the next save.
            if let rowDeps = item.dependsOn {
                f = PatternFamily(
                    id: f.id, name: f.name, kind: f.kind,
                    functionName: f.functionName, paramNames: f.paramNames,
                    defaults: f.defaults, cases: f.cases,
                    variables: f.variables,
                    dependsOn: rowDeps
                )
            }
            authored.append(.family(id: f.id, sectionID: item.sectionID))
            nextFamilies.append(f)
        case "check":
            // Notebook-check rows carry their full spec.  As of the
            // suite-save unification (Phase B) `PUT /suite` is authoritative
            // for the whole test-item list — scripts, families, AND checks
            // — so we collect the spec into `nextChecks` (full-replace,
            // symmetric with `nextFamilies`) and stamp the authored
            // position.  The editor always sends every row's current spec
            // (the seed is refreshed after each `PUT /checks` modal save),
            // so a reorder save round-trips check specs unchanged.  The
            // dedicated `PUT /checks` endpoint stays for the check modal.
            guard let c = item.check else {
                throw WebAssignmentError.invalidParameter(
                    name: "items",
                    reason: "Suite item kind=check is missing `check` payload.")
            }
            authored.append(.check(id: c.id, sectionID: item.sectionID))
            nextChecks.append(c)
        default:
            throw WebAssignmentError.invalidParameter(
                name: "items",
                reason: "Unknown suite item kind '\(item.kind)'.")
        }
    }

    // Section CRUD lives on dedicated endpoints (v0.4.98) — pass `nil`
    // so applyPatternFamilies falls through to the manifest's existing
    // sections list.  The client's body may include `sections` for
    // back-compat but we don't act on it here.
    _ = try await applyPatternFamilies(
        to: setup,
        nextFamilies: nextFamilies,
        nextChecks: nextChecks,
        authoredItems: authored,
        sections: nil,
        on: db
    )
}

// Pattern families and notebook checks no longer have dedicated full-replace
// editor helpers: their writes flow through `applySuiteEdit` above (the single
// PUT /suite path).  The standalone `applyPatternFamiliesEdit` /
// `applyNotebookChecksEdit` helpers — and the PUT /families / PUT /checks
// endpoints they backed — were retired in v0.4.227.

// MARK: - JSON response helper

/// Encodes an `Encodable` payload as a sorted-keys JSON response with
/// `Content-Type: application/json` and the given status.  Used by the
/// PUT endpoints to echo their applied state back to the client.
func jsonResponse<T: Encodable>(_ value: T, status: HTTPResponseStatus = .ok) throws -> Response {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return Response(
        status: status,
        headers: ["Content-Type": "application/json"],
        body: .init(data: data))
}

// MARK: - Manifest dictionary mutation

/// Reads the test setup's manifest JSON as a mutable dictionary, runs
/// the caller's mutation closure, re-serialises with sorted keys, and
/// saves.  Throws if the manifest can't round-trip through
/// JSONSerialization — that would indicate a corrupted setup, not a
/// user error.
///
/// Used by both the assignment-scoped suite-section CRUD endpoints
/// (`AssignmentRoutes+SuiteSections.swift`) and the draft-scoped ones
/// (`AssignmentRoutes+DraftSections.swift`).  Lives here so both can
/// share the same dictionary-of-Any approach — Codable round-trips
/// through `TestProperties` would strip any unknown fields the client
/// might add, defeating the point of forward compatibility.
func mutateManifest(
    setup: APITestSetup,
    on db: Database,
    _ mutate: (inout [String: Any]) throws -> Void
) async throws {
    guard var dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any] else {
        throw WebAssignmentError.internalFailure(reason: "Test setup manifest is not a JSON object.")
    }
    try mutate(&dict)
    let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
    guard let json = String(data: data, encoding: .utf8) else {
        throw WebAssignmentError.internalFailure(reason: "Failed to re-serialise manifest.")
    }
    setup.manifest = json
    try await setup.save(on: db)
}
