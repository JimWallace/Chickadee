// APIServer/Routes/Web/PublishedAssignmentRoutes+Families.swift
//
// Pattern family editor endpoints.  The canonical spec for a family lives in
// the test setup manifest (TestProperties.patternFamilies); these endpoints
// are the single editing surface for that spec.  PUT replaces the whole list
// atomically — validation, zip mutation, and manifest rewrite all happen in
// `applyPatternFamilies`.

import Core
import Fluent
import Foundation
import Vapor

extension PublishedAssignmentRoutes {

    // MARK: - GET /instructor/:assignmentID/families
    //
    // Returns the current list of PatternFamily specs as a JSON array.  Used
    // by the editor JS to seed its in-page state if the page context wasn't
    // enough (e.g. after a save, to refresh).

    @Sendable
    func getPatternFamilies(req: Request) async throws -> Response {
        let (_, setup) = try await loadAssignmentAndSetup(req)

        let families: [PatternFamily] = {
            guard let props = setup.decodedManifest()

            else { return [] }
            return props.patternFamilies
        }()

        return try jsonResponse(families)
    }

    // MARK: - PUT /instructor/:assignmentID/families
    //
    // Replaces the assignment's full pattern family list.  Body is a JSON
    // array of PatternFamily objects.  On success, the test setup zip and
    // manifest are updated in place: new generated scripts written, stale
    // ones removed, manifest rewritten with generatedBy tags on the
    // corresponding test suite entries.  Runner cache invalidates because
    // manifest bytes change.
    //
    // Returns the applied family list (same shape as GET) for the caller
    // to reconcile with any local state.

    @Sendable
    func putPatternFamilies(req: Request) async throws -> Response {
        let (assignment, setup) = try await loadAssignmentAndSetup(req)

        let families: [PatternFamily]
        do {
            families = try req.content.decode([PatternFamily].self)
        } catch {
            throw WebAssignmentError.invalidParameter(
                name: "request body",
                reason: "Invalid pattern family list: \(error.localizedDescription)")
        }

        try await applyPatternFamiliesEdit(setup: setup, families: families, on: req.db)

        // Re-kick validation so the runner picks up the edited manifest.
        // Debounced: a no-op when a pending validation already exists.
        await scheduleValidationAfterSuiteEdit(req: req, assignment: assignment)

        return try jsonResponse(families)
    }
}
