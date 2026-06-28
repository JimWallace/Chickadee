// APIServer/Routes/Web/PublishedAssignmentRoutes+SuiteSections.swift
//
// Per-operation CRUD endpoints for the test-suite Sections feature
// (introduced in v0.4.96, refactored in v0.4.98 to mirror the dashboard
// pattern).  These handlers mutate ONLY the test setup's `manifest.sections`
// JSON field (and, for delete, the `sectionID` field on matching
// `manifest.testSuites` entries).  They intentionally bypass
// `applyPatternFamilies`, the zip rebuild, and the validation/retest
// machinery — section names have no effect on test behaviour, so none of
// that pipeline needs to run.
//
// Pattern mirrors `AssignmentRoutes+Sections.swift`:
//   - form-encoded POST bodies for write ops (create, rename, delete)
//   - 303 redirect back to the edit page on success
//   - JSON POST body for AJAX reorder; returns 200 OK
//   - CSRF via `#csrfFormField()` (or `x-csrf-token` header for AJAX)
//
// The manifest is a JSON string stored in APITestSetup.manifest; we mutate
// it via JSONSerialization to avoid touching the codable TestProperties
// (which is shared with the runner) — that way a future field the client
// knows about but the runner doesn't won't be stripped on save.  Same
// approach `moveToSection` uses for the `gradingMode` field.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    // MARK: - POST /instructor/:assignmentID/suite-sections

    @Sendable
    func createSuiteSection(req: Request) async throws -> Response {
        struct Body: Content { var name: String }

        let (_, setup) = try await loadAssignmentAndSetupForWrite(req)
        let body = try req.content.decode(Body.self)
        try await createSuiteSectionCore(setup: setup, name: body.name, on: req.db)
        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/:sectionID/rename

    @Sendable
    func renameSuiteSection(req: Request) async throws -> Response {
        struct Body: Content { var name: String }

        let (_, setup) = try await loadAssignmentAndSetupForWrite(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        let body = try req.content.decode(Body.self)
        try await renameSuiteSectionCore(setup: setup, sectionID: sectionID, name: body.name, on: req.db)
        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/:sectionID/delete

    @Sendable
    func deleteSuiteSection(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetupForWrite(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        try await deleteSuiteSectionCore(setup: setup, sectionID: sectionID, on: req.db)
        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/:sectionID/variables
    //
    // Replaces the section's variables list atomically.  Body is the full
    // new list (same shape every call); the server doesn't diff.  Takes
    // JSON so the editor can send structured `FamilyVariable` values
    // directly — same shape the `PUT /families` endpoint already uses.
    // Returns 303 so the browser reloads the edit page with the updated
    // section block.

    @Sendable
    func updateSuiteSectionVariables(req: Request) async throws -> Response {
        struct Body: Content {
            var variables: [FamilyVariable]
            /// Slice 4 — per-student expressions in section scope.
            /// Optional so older editor builds (sending only `variables`)
            /// keep working.
            var expressions: [PersonalizationExpression]?
        }

        let (assignment, setup) = try await loadAssignmentAndSetupForWrite(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        let body = try req.content.decode(Body.self)

        // The save-time eval runs against the acting instructor's own seed.
        let actingUserID = (try? req.auth.require(APIUser.self))?.id

        try await SectionInputsService.apply(
            setup: setup,
            sectionID: sectionID,
            inputs: .init(variables: body.variables, expressions: body.expressions ?? []),
            seed: .init(
                actingUserID: actingUserID,
                assignmentID: assignment.id,
                testSetupID: assignment.testSetupID,
                testSetupsDirectory: req.application.testSetupsDirectory),
            on: req.db,
            // Web requests use one (owner) pool; seed bookkeeping and content
            // share it here. The split only matters on the MCP least-privilege path.
            seedDB: req.db
        )

        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/reorder

    @Sendable
    func reorderSuiteSections(req: Request) async throws -> HTTPStatus {
        struct Body: Content { var sectionIDs: [String] }

        let (_, setup) = try await loadAssignmentAndSetupForWrite(req)
        let body = try req.content.decode(Body.self)
        try await reorderSuiteSectionsCore(setup: setup, sectionIDs: body.sectionIDs, on: req.db)
        return .ok
    }

    // MARK: - Helpers

    /// Build the 303 redirect back to the assignment edit page using the
    /// request's `:assignmentID` parameter, so the browser reloads into a
    /// freshly-rendered view of the new section state.
    private func redirectToEdit(req: Request) -> Response {
        let idStr = (try? assignmentPublicIDParameter(from: req)) ?? ""
        return req.redirect(to: "/instructor/\(idStr)/edit")
    }
}
