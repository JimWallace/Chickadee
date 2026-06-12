// APIServer/Routes/Web/DraftAssignmentRoutes+Sections.swift
//
// Draft-scoped siblings of the test-suite section CRUD endpoints in
// `AssignmentRoutes+SuiteSections.swift`.  Same body shapes, same
// validation rules, same dictionary-of-Any manifest mutations — the
// only differences are (1) the resolver (`loadDraftSetup` reading
// `?draftID=<id>` instead of `loadAssignmentAndSetup` reading
// `:assignmentID`) and (2) the redirect target
// (`/instructor/new?draftID=<id>` instead of
// `/instructor/<aid>/edit`).
//
// Added in v0.4.132 as parity PR 1 of the create-page rework tracked
// by issue #433.  Pre-fix, instructors had to publish an assignment
// before they could group tests into sections — confusing two-step
// when sections were the whole reason they were authoring the
// assignment in the first place.
//
// Routes (all share the `?draftID=<id>` query parameter):
//   POST   /instructor/new/draft/suite-sections                       — create
//   POST   /instructor/new/draft/suite-sections/reorder               — reorder (AJAX)
//   POST   /instructor/new/draft/suite-sections/:sectionID/rename     — rename
//   POST   /instructor/new/draft/suite-sections/:sectionID/delete     — delete
//   POST   /instructor/new/draft/suite-sections/:sectionID/variables  — variables

import Core
import Fluent
import Foundation
import Vapor

extension DraftAssignmentRoutes {

    // MARK: - POST /instructor/new/draft/suite-sections

    @Sendable
    func createDraftSuiteSection(req: Request) async throws -> Response {
        struct Body: Content { var name: String }

        let setup = try await loadDraftSetup(req)
        let body = try req.content.decode(Body.self)
        try await createSuiteSectionCore(setup: setup, name: body.name, on: req.db)
        return redirectToDraft(req: req, setup: setup)
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sectionID/rename

    @Sendable
    func renameDraftSuiteSection(req: Request) async throws -> Response {
        struct Body: Content { var name: String }

        let setup = try await loadDraftSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        let body = try req.content.decode(Body.self)
        try await renameSuiteSectionCore(setup: setup, sectionID: sectionID, name: body.name, on: req.db)
        return redirectToDraft(req: req, setup: setup)
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sectionID/delete

    @Sendable
    func deleteDraftSuiteSection(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        try await deleteSuiteSectionCore(setup: setup, sectionID: sectionID, on: req.db)
        return redirectToDraft(req: req, setup: setup)
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sectionID/variables
    //
    // Replaces the section's variables (and per-student expressions) list
    // atomically, through the same `SectionInputsService.apply` path the
    // published endpoint uses — so a draft gets the identical validation
    // (Python-identifier, reserved-`seed`, cross-scope clash) AND expression
    // support. The save-time expression eval no-ops here: a draft has no
    // assignment seed yet (`assignmentID: nil`), so expressions are persisted
    // and first evaluated when the assignment is published. Returns 303 on the
    // form-encoded path; the auto-save JS sends `redirect: 'manual'` so it
    // doesn't follow the redirect back to the create page.

    @Sendable
    func updateDraftSuiteSectionVariables(req: Request) async throws -> Response {
        struct Body: Content {
            var variables: [FamilyVariable]
            /// Per-student expressions in section scope (optional so older
            /// editor builds sending only `variables` keep working).
            var expressions: [PersonalizationExpression]?
        }

        let setup = try await loadDraftSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        let body = try req.content.decode(Body.self)
        let actingUserID = (try? req.auth.require(APIUser.self))?.id

        try await SectionInputsService.apply(
            setup: setup,
            sectionID: sectionID,
            inputs: .init(variables: body.variables, expressions: body.expressions ?? []),
            seed: .init(
                actingUserID: actingUserID,
                assignmentID: nil,
                testSetupID: setup.id ?? "",
                testSetupsDirectory: req.application.testSetupsDirectory),
            on: req.db
        )

        return redirectToDraft(req: req, setup: setup)
    }

    // MARK: - POST /instructor/new/draft/suite-sections/reorder

    @Sendable
    func reorderDraftSuiteSections(req: Request) async throws -> HTTPStatus {
        struct Body: Content { var sectionIDs: [String] }

        let setup = try await loadDraftSetup(req)
        let body = try req.content.decode(Body.self)
        try await reorderSuiteSectionsCore(setup: setup, sectionIDs: body.sectionIDs, on: req.db)
        return .ok
    }

    // MARK: - Helpers

    /// 303 redirect back to the create-assignment page, preserving the
    /// `?draftID=<id>` query so the page reloads on the same draft.
    private func redirectToDraft(req: Request, setup: APITestSetup) -> Response {
        let id = setup.id ?? ""
        return req.redirect(to: "/instructor/new?draftID=\(id)")
    }
}
