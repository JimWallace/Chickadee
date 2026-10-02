// APIServer/Routes/Web/SuiteEditHelpers.swift
//
// The assignment loaders (`loadAssignment*ForStaffRead` and `*ForWrite`)
// live in AssignmentHelpers.swift: most of their callers are not suite
// editing (#1717). The draft loaders stay here.
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

// MARK: - Draft resolution

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
    kernelEnvironments: KernelEnvironments? = nil,
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
                        timeLimitSeconds: s.timeLimitSeconds,
                        failureDetail: try parseFailureDetail(s.failureDetail, script: s.script)
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
                f = f.replacingDependsOn(rowDeps)
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
        try await KernelImportGuard.check(
            filename: s.script, content: content, setup: setup, environments: kernelEnvironments)
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

// MARK: - Manifest mutation

/// Decodes the test setup's manifest, runs the caller's mutation on the
/// `TestProperties` value, encodes it with the stable encoder and saves.
/// Throws if the manifest does not decode — that indicates a corrupted
/// setup, not a user error.
///
/// Every single-field edit goes through here (`ManifestFieldEdits.swift`,
/// the suite-section CRUD, the MCP tools), so there is one writer of a
/// stored manifest.  It used to edit a `[String: Any]` dictionary so that a
/// key the server did not model would survive an edit; nothing ever read
/// such a key, and the suite rebuild (`makeWorkerManifestJSON`) dropped it
/// anyway.  A typed edit cannot misspell a key or drop a field it did not
/// think to carry.
func mutateManifest(
    setup: APITestSetup,
    on db: Database,
    _ mutate: (inout TestProperties) throws -> Void
) async throws {
    guard var props = setup.decodedManifest() else {
        throw WebAssignmentError.internalFailure(reason: "Test setup manifest could not be decoded.")
    }
    try mutate(&props)
    setup.manifest = try encodeManifest(props)
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
    try await mutateManifest(setup: setup, on: db) { props in
        props.sections.append(TestSuiteSection(id: UUID().uuidString, name: trimmed))
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
    try await mutateManifest(setup: setup, on: db) { props in
        guard let idx = props.sections.firstIndex(where: { $0.id == sectionID }) else {
            throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
        }
        props.sections[idx].name = trimmed
    }
}

/// Removes the section and clears the `sectionID` of any test-suite entries
/// that referenced it, so they flow into the trailing Ungrouped block (same
/// semantics as `onDelete: .setNull` on course_sections).
func deleteSuiteSectionCore(setup: APITestSetup, sectionID: String, on db: any Database) async throws {
    try await mutateManifest(setup: setup, on: db) { props in
        props.sections.removeAll { $0.id == sectionID }
        for i in props.testSuites.indices where props.testSuites[i].sectionID == sectionID {
            props.testSuites[i].sectionID = nil
        }
    }
}

/// Reorders the section list to match `sectionIDs`, which must be a permutation
/// of the existing ids.
func reorderSuiteSectionsCore(
    setup: APITestSetup, sectionIDs: [String], on db: any Database
) async throws {
    try await mutateManifest(setup: setup, on: db) { props in
        let byID = Dictionary(props.sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard Set(sectionIDs) == Set(byID.keys), sectionIDs.count == props.sections.count else {
            throw WebAssignmentError.invalidParameter(
                name: "sectionIDs", reason: "Section set mismatch in reorder payload.")
        }
        props.sections = sectionIDs.compactMap { byID[$0] }
    }
}

/// Maps a `ScriptDTO.failureDetail` string to the enum: absent or empty means
/// "full" (stored as nil), an unknown token is refused rather than silently
/// dropped, since a dropped setting would show a student the answer the
/// instructor meant to withhold.
func parseFailureDetail(_ raw: String?, script: String) throws -> FailureDetail? {
    guard let raw, !raw.isEmpty else { return nil }
    guard let detail = FailureDetail(rawValue: raw) else {
        throw WebAssignmentError.invalidParameter(
            name: "failureDetail",
            reason:
                "Script \(script): failureDetail must be one of "
                + FailureDetail.allCases.map(\.rawValue).joined(separator: ", ") + ".")
    }
    return detail == .full ? nil : detail
}
