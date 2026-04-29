// APIServer/Routes/Web/AssignmentRoutes+SuiteSections.swift
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

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    // MARK: - POST /instructor/:assignmentID/suite-sections

    @Sendable
    func createSuiteSection(req: Request) async throws -> Response {
        struct Body: Content { var name: String }

        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(Body.self)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Section name must not be empty.")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            var sections = (dict["sections"] as? [[String: Any]]) ?? []
            sections.append([
                "id":   UUID().uuidString,
                "name": name,
            ])
            dict["sections"] = sections
        }

        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/:sectionID/rename

    @Sendable
    func renameSuiteSection(req: Request) async throws -> Response {
        struct Body: Content { var name: String }

        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(Body.self)
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw Abort(.badRequest, reason: "Section name must not be empty.")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            guard var sections = dict["sections"] as? [[String: Any]] else {
                throw Abort(.notFound, reason: "Section '\(sectionID)' not found.")
            }
            guard let idx = sections.firstIndex(where: { ($0["id"] as? String) == sectionID }) else {
                throw Abort(.notFound, reason: "Section '\(sectionID)' not found.")
            }
            sections[idx]["name"] = name
            dict["sections"] = sections
        }

        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/:sectionID/delete

    @Sendable
    func deleteSuiteSection(req: Request) async throws -> Response {
        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw Abort(.notFound)
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            // Drop the section from the list.
            if var sections = dict["sections"] as? [[String: Any]] {
                sections.removeAll { ($0["id"] as? String) == sectionID }
                dict["sections"] = sections
            }
            // Clear matching entries' sectionID so the affected items flow
            // into the trailing Ungrouped block — same semantics as the
            // dashboard's onDelete: .setNull on course_sections.
            if var testSuites = dict["testSuites"] as? [[String: Any]] {
                for i in testSuites.indices {
                    if (testSuites[i]["sectionID"] as? String) == sectionID {
                        testSuites[i].removeValue(forKey: "sectionID")
                    }
                }
                dict["testSuites"] = testSuites
            }
        }

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
        struct Body: Content { var variables: [FamilyVariable] }

        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw Abort(.notFound)
        }
        let body = try req.content.decode(Body.self)

        // Validate: each name must be a valid Python identifier and
        // unique within the list.  Mirrors the `validatePatternFamilies`
        // checks so a bad section-variable save can't produce a test
        // that won't render.
        var seenNames: Set<String> = []
        for v in body.variables {
            guard isValidPythonIdentifier(v.name) else {
                throw Abort(.unprocessableEntity,
                    reason: "Section variable name '\(v.name)' is not a valid Python identifier.")
            }
            guard seenNames.insert(v.name).inserted else {
                throw Abort(.unprocessableEntity,
                    reason: "Duplicate section variable name '\(v.name)'.")
            }
        }

        // Encode the variables list via JSONEncoder so JSONValue fields
        // (dict / list / scalar) round-trip through `mutateManifest`'s
        // dictionary-of-Any representation.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let varData = try encoder.encode(body.variables)
        guard let parsed = try JSONSerialization.jsonObject(with: varData) as? [Any] else {
            throw Abort(.internalServerError, reason: "Failed to re-serialise section variables.")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            guard var sections = dict["sections"] as? [[String: Any]] else {
                throw Abort(.notFound, reason: "Section '\(sectionID)' not found.")
            }
            guard let idx = sections.firstIndex(where: { ($0["id"] as? String) == sectionID }) else {
                throw Abort(.notFound, reason: "Section '\(sectionID)' not found.")
            }
            if parsed.isEmpty {
                sections[idx].removeValue(forKey: "variables")
            } else {
                sections[idx]["variables"] = parsed
            }
            dict["sections"] = sections
        }

        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/reorder

    @Sendable
    func reorderSuiteSections(req: Request) async throws -> HTTPStatus {
        struct Body: Content { var sectionIDs: [String] }

        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
        let body = try req.content.decode(Body.self)

        try await mutateManifest(setup: setup, on: req.db) { dict in
            let existing = (dict["sections"] as? [[String: Any]]) ?? []
            let byID = Dictionary(
                uniqueKeysWithValues: existing.compactMap { s -> (String, [String: Any])? in
                    guard let id = s["id"] as? String else { return nil }
                    return (id, s)
                }
            )
            // Validate the set of ids matches exactly.
            guard Set(body.sectionIDs) == Set(byID.keys),
                  body.sectionIDs.count == existing.count else {
                throw Abort(.badRequest, reason: "Section set mismatch in reorder payload.")
            }
            dict["sections"] = body.sectionIDs.compactMap { byID[$0] }
        }

        return .ok
    }

    // MARK: - Helpers

    /// Reads the manifest JSON as a mutable dictionary, runs the caller's
    /// mutation closure, re-serialises, and saves.  Throws if the manifest
    /// can't round-trip through JSONSerialization — that would indicate a
    /// corrupted setup, not a user error.
    private func mutateManifest(
        setup: APITestSetup,
        on db: Database,
        _ mutate: (inout [String: Any]) throws -> Void
    ) async throws {
        guard var dict = (try? JSONSerialization.jsonObject(with: Data(setup.manifest.utf8))) as? [String: Any] else {
            throw Abort(.internalServerError, reason: "Test setup manifest is not a JSON object.")
        }
        try mutate(&dict)
        let data = try JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        guard let json = String(data: data, encoding: .utf8) else {
            throw Abort(.internalServerError, reason: "Failed to re-serialise manifest.")
        }
        setup.manifest = json
        try await setup.save(on: db)
    }

    /// Build the 303 redirect back to the assignment edit page using the
    /// request's `:assignmentID` parameter, so the browser reloads into a
    /// freshly-rendered view of the new section state.
    private func redirectToEdit(req: Request) -> Response {
        let idStr = (try? assignmentPublicIDParameter(from: req)) ?? ""
        return req.redirect(to: "/instructor/\(idStr)/edit")
    }
}
