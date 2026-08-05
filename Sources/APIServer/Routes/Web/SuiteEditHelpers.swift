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
///
/// Performs **no authorization** — private so unauthorized use is impossible
/// outside this file. Handlers go through `loadAssignmentAndSetupForStaffRead`
/// or `loadAssignmentAndSetupForWrite`, which scope the caller to the
/// assignment's own course (#1103).
private func loadAssignmentAndSetup(_ req: Request) async throws -> (APIAssignment, APITestSetup) {
    let idStr = try assignmentPublicIDParameter(from: req)
    guard
        let assignment = try await assignmentByPublicID(idStr, on: req.db),
        let setup = try await APITestSetup.find(assignment.testSetupID, on: req.db)
    else { throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'") }
    return (assignment, setup)
}

/// Lighter sibling of `loadAssignmentAndSetup(_:)` for handlers that never
/// touch the test setup — same `:assignmentID` resolution and 404 message,
/// without forcing an unnecessary `APITestSetup` fetch.  Handlers that need
/// the raw path parameter afterwards can use `assignment.publicID`, which
/// is always identical to it (`assignmentByPublicID` is an exact-match
/// filter on a validated parameter).
///
/// Performs **no authorization** by itself. Callers must either go through
/// `loadAssignmentForStaffRead` / `loadAssignmentForWrite`, or — like
/// `resolveStudentAssignmentAction` and `moveToSection` — apply their own
/// per-course gate immediately after loading (#1103).
func loadAssignment(_ req: Request) async throws -> APIAssignment {
    let idStr = try assignmentPublicIDParameter(from: req)
    guard let assignment = try await assignmentByPublicID(idStr, on: req.db) else {
        throw WebAssignmentError.notFound(resource: "Assignment '\(idStr)'")
    }
    return assignment
}

/// Read-authorizing sibling of `loadAssignmentAndSetup(_:)`. After loading,
/// requires the caller hold at least a `.ta` role in the assignment's **own**
/// course (`requireCourseRole`, admin bypass). Unlike the write loader there is
/// no archived-course block, so archived courses stay readable for audits.
///
/// The editor read handlers (suite/scripts/files/achievements/datasets/
/// global-variables/edit-page) use this so a staff member of course A can't
/// fetch course B's reference solution or secret tests by guessing its 6-char
/// assignment public ID — the same cross-course hole #417 Slice G closed on
/// the API side (`downloadTestSetup`), missed on the web editor (#1103).
func loadAssignmentAndSetupForStaffRead(_ req: Request) async throws -> (APIAssignment, APITestSetup) {
    let (assignment, setup) = try await loadAssignmentAndSetup(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseRole(caller: caller, courseID: assignment.courseID, atLeast: .ta, db: req.db)
    return (assignment, setup)
}

/// Read-authorizing sibling of `loadAssignment(_:)` — same `.ta` staff gate as
/// `loadAssignmentAndSetupForStaffRead`, for read-only pages that never touch
/// the test setup (per-assignment submissions list, per-student history). No
/// archived-course block, so archived courses stay auditable (#1103).
func loadAssignmentForStaffRead(_ req: Request) async throws -> APIAssignment {
    let assignment = try await loadAssignment(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseRole(caller: caller, courseID: assignment.courseID, atLeast: .ta, db: req.db)
    return assignment
}

/// Write-authorizing sibling of `loadAssignmentAndSetup(_:)`. After loading,
/// authorizes the caller for a *write* to the assignment's **own** course via
/// `requireCourseWriteAccess` (per-course role + admin bypass + archived-course
/// block). Mutating editor handlers use this so a write is scoped to the
/// resource's course rather than the caller's active course — closing both the
/// archived-course and cross-course write paths the `/instructor` group
/// middleware can't see (see docs/multi-course-roles.md).
///
/// Callers state their floor explicitly (#1113): the assignment **content**
/// editor handlers (suite/scripts/sections/families/checks/global-inputs/
/// datasets/achievements/notebook/solution/save-edit/retest-all) pass `.ta` —
/// all of which a TA may do. The one structural caller, `cloneAssignment`
/// (it creates a new assignment), passes `.instructor` (#417 Slice E).
func loadAssignmentAndSetupForWrite(
    _ req: Request, atLeast: CourseRole
) async throws -> (APIAssignment, APITestSetup) {
    let (assignment, setup) = try await loadAssignmentAndSetup(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseWriteAccess(
        caller: caller, courseID: assignment.courseID, atLeast: atLeast, db: req.db)
    // Content-versioning seam: seeds the pre-edit baseline and registers the
    // setup so `AssignmentVersionCaptureMiddleware` snapshots it if this
    // request succeeds. Handlers that turn out not to change content cost
    // nothing — the snapshot dedupes to no row.
    await req.beginAssignmentContentEdit(setup: setup)
    return (assignment, setup)
}

/// Write-authorizing sibling of `loadAssignment(_:)`, for handlers that mutate
/// per-course state but never touch the test setup. Same `requireCourseWriteAccess`
/// gate as `loadAssignmentAndSetupForWrite`, scoping the write to the
/// assignment's **own** course (#417, follow-up to Slice A).
///
/// Callers state their floor explicitly (#1113): per-student grading actions
/// (retest/reset/grade-override — TA-allowed) pass `.ta`; assignment-lifecycle
/// actions (open/close/status/delete/BrightSpace — instructor-only) pass
/// `.instructor` (#417 Slice E).
func loadAssignmentForWrite(
    _ req: Request, atLeast: CourseRole
) async throws -> APIAssignment {
    let assignment = try await loadAssignment(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseWriteAccess(
        caller: caller, courseID: assignment.courseID, atLeast: atLeast, db: req.db)
    return assignment
}

/// Loads a draft test setup from the `?draftID=<id>` query parameter.
/// The draft model is just an `APITestSetup` row that hasn't been
/// linked to an `APIAssignment` yet — same row shape, no parent.
/// Throws `.badRequest` if the parameter is missing/empty,
/// `.notFound` if no row matches.
///
/// Performs **no authorization** — private, like `loadAssignmentAndSetup`.
/// Handlers go through the read/write variants below, which both scope the
/// caller to the draft's own course (#1103; supersedes the Bool
/// `requireWrite:` flag whose `false` case skipped authorization entirely).
private func loadDraftSetup(_ req: Request) async throws -> APITestSetup {
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

/// Read-authorizing draft loader: the caller must hold at least a `.ta` role
/// in the draft's own course (admin bypass; no archived block). Used by
/// `getDraftSuite` / `downloadDraftSetupItem` so a staff member of another
/// course can't read a draft's suite or support files by guessing its
/// `draftID` (#1103).
func loadDraftSetupForRead(_ req: Request) async throws -> APITestSetup {
    let setup = try await loadDraftSetup(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseRole(caller: caller, courseID: setup.courseID, atLeast: .ta, db: req.db)
    return setup
}

/// Write-authorizing draft loader (`requireCourseWriteAccess`): the draft
/// suite/script/section edit handlers use this so an instructor can't mutate
/// another course's draft — or one in an archived course — by guessing its
/// `draftID` (#417 Slice D).
func loadDraftSetupForWrite(_ req: Request) async throws -> APITestSetup {
    let setup = try await loadDraftSetup(req)
    let caller = try req.auth.require(APIUser.self)
    try await requireCourseWriteAccess(caller: caller, courseID: setup.courseID, atLeast: .instructor, db: req.db)
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
    kernelEnvironment: KernelPythonEnvironment? = nil,
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
                        content: s.content,
                        hint: s.hint,
                        timeLimitSeconds: s.timeLimitSeconds
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

    // Refuse browser-graded Python scripts whose imports the grading kernel
    // cannot satisfy. Only items that CARRY new content are checked: a reorder
    // or a tier change re-inlines existing files without supplying content, and
    // failing those would make an unrelated save impossible to complete.
    for item in body.items where item.kind == "script" {
        guard let s = item.script, let content = s.content else { continue }
        try PythonImportGuard.check(
            filename: s.script, content: content, setup: setup, environment: kernelEnvironment)
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

// MARK: - Suite-section manifest mutations
//
// Shared cores for the test-suite Sections CRUD, used by both the published
// (`PublishedAssignmentRoutes+SuiteSections`) and draft
// (`DraftAssignmentRoutes+Sections`) handlers. The handlers differ only in how
// they resolve the setup and where they redirect afterward; the manifest
// mutations are identical, so they live here once. (Section variables are
// handled by `SectionInputsService`, which both paths call directly.)

/// Appends a new, uniquely-identified section with the given display name.
func createSuiteSectionCore(setup: APITestSetup, name: String, on db: any Database) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw WebAssignmentError.invalidParameter(name: "name", reason: "Section name must not be empty.")
    }
    try await mutateManifest(setup: setup, on: db) { dict in
        var sections = (dict["sections"] as? [[String: Any]]) ?? []
        sections.append(["id": UUID().uuidString, "name": trimmed])
        dict["sections"] = sections
    }
}

/// Renames the section with `sectionID`, throwing `notFound` if it is absent.
func renameSuiteSectionCore(
    setup: APITestSetup, sectionID: String, name: String, on db: any Database
) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        throw WebAssignmentError.invalidParameter(name: "name", reason: "Section name must not be empty.")
    }
    try await mutateManifest(setup: setup, on: db) { dict in
        guard var sections = dict["sections"] as? [[String: Any]],
            let idx = sections.firstIndex(where: { ($0["id"] as? String) == sectionID })
        else {
            throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
        }
        sections[idx]["name"] = trimmed
        dict["sections"] = sections
    }
}

/// Removes the section and clears the `sectionID` of any test-suite entries
/// that referenced it, so they flow into the trailing Ungrouped block (same
/// semantics as `onDelete: .setNull` on course_sections).
func deleteSuiteSectionCore(setup: APITestSetup, sectionID: String, on db: any Database) async throws {
    try await mutateManifest(setup: setup, on: db) { dict in
        if var sections = dict["sections"] as? [[String: Any]] {
            sections.removeAll { ($0["id"] as? String) == sectionID }
            dict["sections"] = sections
        }
        if var testSuites = dict["testSuites"] as? [[String: Any]] {
            for i in testSuites.indices where (testSuites[i]["sectionID"] as? String) == sectionID {
                testSuites[i].removeValue(forKey: "sectionID")
            }
            dict["testSuites"] = testSuites
        }
    }
}

/// Reorders the section list to match `sectionIDs`, which must be a permutation
/// of the existing ids.
func reorderSuiteSectionsCore(
    setup: APITestSetup, sectionIDs: [String], on db: any Database
) async throws {
    try await mutateManifest(setup: setup, on: db) { dict in
        let existing = (dict["sections"] as? [[String: Any]]) ?? []
        let byID = Dictionary(
            uniqueKeysWithValues: existing.compactMap { s -> (String, [String: Any])? in
                guard let id = s["id"] as? String else { return nil }
                return (id, s)
            }
        )
        guard Set(sectionIDs) == Set(byID.keys), sectionIDs.count == existing.count else {
            throw WebAssignmentError.invalidParameter(
                name: "sectionIDs", reason: "Section set mismatch in reorder payload.")
        }
        dict["sections"] = sectionIDs.compactMap { byID[$0] }
    }
}
