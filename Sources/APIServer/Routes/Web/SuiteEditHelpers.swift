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

// The suite-list edit (`applySuiteEdit`) and `jsonResponse` are in
// `Services/SuiteEditing.swift`, because the MCP tools use them too (#2496).

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
