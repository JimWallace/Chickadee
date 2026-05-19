// APIServer/Routes/Web/PublishedAssignmentRoutes+Checks.swift
//
// Notebook check editor endpoints.  Sibling to AssignmentRoutes+Families.swift
// for the parallel concept introduced in the data-science autograding
// roadmap (Tier-A onward).  PUT replaces the whole list atomically — the
// shared `applyPatternFamilies` save path takes the new checks alongside
// the existing families and rebuilds the test setup zip + manifest in one
// pass.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    // MARK: - GET /instructor/:assignmentID/checks
    //
    // Returns the current list of NotebookCheck specs as a JSON array.
    // Counterpart to GET /families.

    @Sendable
    func getNotebookChecks(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetup(req)

        let checks: [NotebookCheck] = {
            guard let props = setup.decodedManifest()

            else { return [] }
            return props.notebookChecks
        }()

        return try jsonResponse(checks)
    }

    // MARK: - PUT /instructor/:assignmentID/checks
    //
    // Replaces the assignment's full notebook check list.  Body is a JSON
    // array of NotebookCheck objects.  On success, the test setup zip and
    // manifest are updated: new generated scripts written, stale ones
    // removed, manifest rewritten with `generatedByCheck` tags on the
    // corresponding test suite entries.  Existing pattern families on the
    // manifest are preserved untouched (the apply path's `nextFamilies`
    // gets the current manifest's list).

    @Sendable
    func putNotebookChecks(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetup(req)

        let checks: [NotebookCheck]
        do {
            checks = try req.content.decode([NotebookCheck].self)
        } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid notebook check list: \(error.localizedDescription)")
        }

        try await applyNotebookChecksEdit(setup: setup, checks: checks, on: req.db)

        await scheduleValidationAfterSuiteEdit(req: req, assignment: assignment)

        return try jsonResponse(checks)
    }
}
