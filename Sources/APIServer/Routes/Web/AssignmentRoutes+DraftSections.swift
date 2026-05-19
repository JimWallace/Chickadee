// APIServer/Routes/Web/AssignmentRoutes+DraftSections.swift
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
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Section name must not be empty.")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            var sections = (dict["sections"] as? [[String: Any]]) ?? []
            sections.append([
                "id": UUID().uuidString,
                "name": name,
            ])
            dict["sections"] = sections
        }

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
        let name = body.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw WebAssignmentError.invalidParameter(name: "name", reason: "Section name must not be empty.")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            guard var sections = dict["sections"] as? [[String: Any]] else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            guard let idx = sections.firstIndex(where: { ($0["id"] as? String) == sectionID }) else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            sections[idx]["name"] = name
            dict["sections"] = sections
        }

        return redirectToDraft(req: req, setup: setup)
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sectionID/delete

    @Sendable
    func deleteDraftSuiteSection(req: Request) async throws -> Response {
        let setup = try await loadDraftSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            // Drop the section from the list.
            if var sections = dict["sections"] as? [[String: Any]] {
                sections.removeAll { ($0["id"] as? String) == sectionID }
                dict["sections"] = sections
            }
            // Clear matching entries' sectionID so the affected items flow
            // into the trailing Ungrouped block — same semantics as the
            // assignment-scoped variant.
            if var testSuites = dict["testSuites"] as? [[String: Any]] {
                for i in testSuites.indices where (testSuites[i]["sectionID"] as? String) == sectionID {
                    testSuites[i].removeValue(forKey: "sectionID")
                }
                dict["testSuites"] = testSuites
            }
        }

        return redirectToDraft(req: req, setup: setup)
    }

    // MARK: - POST /instructor/new/draft/suite-sections/:sectionID/variables
    //
    // Replaces the section's variables list atomically.  Shape matches
    // the assignment-scoped endpoint: JSON body with `variables:
    // [FamilyVariable]`; identical Python-identifier + uniqueness
    // validation.  Returns 303 on the form-encoded path; the auto-save
    // JS sends `redirect: 'manual'` so it doesn't follow the redirect
    // back to the create page.

    @Sendable
    func updateDraftSuiteSectionVariables(req: Request) async throws -> Response {
        struct Body: Content { var variables: [FamilyVariable] }

        let setup = try await loadDraftSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        let body = try req.content.decode(Body.self)

        var seenNames: Set<String> = []
        for v in body.variables {
            guard isValidPythonIdentifier(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Section variable name '\(v.name)' is not a valid Python identifier.")
            }
            guard seenNames.insert(v.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate section variable name '\(v.name)'.")
            }
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let varData = try encoder.encode(body.variables)
        guard let parsed = try JSONSerialization.jsonObject(with: varData) as? [Any] else {
            throw WebAssignmentError.internalFailure(reason: "Failed to re-serialise section variables.")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            guard var sections = dict["sections"] as? [[String: Any]] else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            guard let idx = sections.firstIndex(where: { ($0["id"] as? String) == sectionID }) else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            if parsed.isEmpty {
                sections[idx].removeValue(forKey: "variables")
            } else {
                sections[idx]["variables"] = parsed
            }
            dict["sections"] = sections
        }

        return redirectToDraft(req: req, setup: setup)
    }

    // MARK: - POST /instructor/new/draft/suite-sections/reorder

    @Sendable
    func reorderDraftSuiteSections(req: Request) async throws -> HTTPStatus {
        struct Body: Content { var sectionIDs: [String] }

        let setup = try await loadDraftSetup(req)
        let body = try req.content.decode(Body.self)

        try await mutateManifest(setup: setup, on: req.db) { dict in
            let existing = (dict["sections"] as? [[String: Any]]) ?? []
            let byID = Dictionary(
                uniqueKeysWithValues: existing.compactMap { s -> (String, [String: Any])? in
                    guard let id = s["id"] as? String else { return nil }
                    return (id, s)
                }
            )
            guard Set(body.sectionIDs) == Set(byID.keys),
                body.sectionIDs.count == existing.count
            else {
                throw WebAssignmentError.invalidParameter(
                    name: "sectionIDs", reason: "Section set mismatch in reorder payload.")
            }
            dict["sections"] = body.sectionIDs.compactMap { byID[$0] }
        }

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
