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

import Core
import Fluent
import Foundation
import Vapor

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

        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/:sectionID/rename

    @Sendable
    func renameSuiteSection(req: Request) async throws -> Response {
        struct Body: Content { var name: String }

        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
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

        return redirectToEdit(req: req)
    }

    // MARK: - POST /instructor/:assignmentID/suite-sections/:sectionID/delete

    @Sendable
    func deleteSuiteSection(req: Request) async throws -> Response {
        try requireInstructor(req)
        let (_, setup) = try await loadAssignmentAndSetup(req)
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
            // dashboard's onDelete: .setNull on course_sections.
            if var testSuites = dict["testSuites"] as? [[String: Any]] {
                for i in testSuites.indices where (testSuites[i]["sectionID"] as? String) == sectionID {
                    testSuites[i].removeValue(forKey: "sectionID")
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
        struct Body: Content {
            var variables: [FamilyVariable]
            /// Slice 4 — per-student expressions in section scope.
            /// Optional so older editor builds (sending only `variables`)
            /// keep working.
            var expressions: [PersonalizationExpression]?
        }

        try requireInstructor(req)
        let (assignment, setup) = try await loadAssignmentAndSetup(req)
        guard let sectionID = req.parameters.get("sectionID"), !sectionID.isEmpty else {
            throw WebAssignmentError.notFound(resource: "Section")
        }
        let body = try req.content.decode(Body.self)
        let expressions = body.expressions ?? []

        // Per-row validation across both literal vars and expressions in
        // this section.  Names are unique across both kinds (single
        // Python namespace at evaluation time).  Mirrors the
        // global-variables endpoint pattern.
        var seenNames: Set<String> = []
        for v in body.variables {
            guard isValidPythonIdentifier(v.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Section input name '\(v.name)' is not a valid Python identifier.")
            }
            guard v.name != "seed" else {
                throw WebAssignmentError.unprocessable(
                    reason: "'seed' is reserved for Chickadee's personalization seed.")
            }
            guard seenNames.insert(v.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate section input name '\(v.name)'.")
            }
        }
        for e in expressions {
            guard isValidPythonIdentifier(e.name) else {
                throw WebAssignmentError.unprocessable(
                    reason: "Section expression name '\(e.name)' is not a valid Python identifier.")
            }
            guard e.name != "seed" else {
                throw WebAssignmentError.unprocessable(
                    reason: "'seed' is reserved for Chickadee's personalization seed.")
            }
            let trimmed = e.expression.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw WebAssignmentError.unprocessable(
                    reason: "Section expression '\(e.name)' has an empty body. "
                        + "Provide a Python expression after the leading `=`.")
            }
            guard seenNames.insert(e.name).inserted else {
                throw WebAssignmentError.unprocessable(
                    reason: "Duplicate section input name '\(e.name)'. "
                        + "Names must be unique across literal values and expressions.")
            }
        }

        // Cross-section + global clash: no name in this section's combined
        // namespace may collide with a name in `globalVariables`,
        // `globalExpressions`, or any OTHER section's variables/expressions.
        guard let manifestData = setup.manifest.data(using: .utf8),
            let manifest = try? ManifestCodec.decoder.decode(
                TestProperties.self,
                from: manifestData)
        else {
            throw WebAssignmentError.internalFailure(reason: "Manifest is not valid JSON.")
        }
        var otherNames: Set<String> = []
        for v in manifest.globalVariables { otherNames.insert(v.name) }
        for e in manifest.globalExpressions { otherNames.insert(e.name) }
        for section in manifest.sections where section.id != sectionID {
            for v in section.variables { otherNames.insert(v.name) }
            for e in section.expressions { otherNames.insert(e.name) }
        }
        for n in seenNames where otherNames.contains(n) {
            throw WebAssignmentError.unprocessable(
                reason: "Section input '\(n)' is already used by a global input or another section. "
                    + "Names share one namespace across the assignment; rename to avoid shadowing.")
        }

        // Save-time eval check: run every expression once against the
        // instructor's own seed so typos surface as a 400.
        if !expressions.isEmpty,
            let userID = (try req.auth.require(APIUser.self)).id,
            let assignmentID = assignment.id
        {
            let seedHex = try await AssignmentSeedStore.ensureSeed(
                userID: userID, assignmentID: assignmentID, on: req.db)
            // Combine: globals + section vars from THIS section's new
            // list + other sections' vars (matches the runtime scope
            // the evaluator will use at first-open).
            var staticVars: [FamilyVariable] = manifest.globalVariables
            staticVars.append(contentsOf: body.variables)
            for section in manifest.sections where section.id != sectionID {
                staticVars.append(contentsOf: section.variables)
            }
            do {
                _ = try await PersonalizationEvaluator.evaluate(
                    seedHex: seedHex,
                    staticVariables: staticVars,
                    expressions: expressions,
                    supportFilesDirectory: req.application.testSetupsDirectory + "shared/\(assignment.testSetupID)/"
                )
            } catch let PersonalizationEvaluatorError.nonZeroExit(_, stderr) {
                let tail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
                throw WebAssignmentError.unprocessable(
                    reason: "One of your section expressions failed to evaluate: \(tail). "
                        + "Fix the expression(s) and save again.")
            } catch PersonalizationEvaluatorError.timedOut {
                throw WebAssignmentError.unprocessable(
                    reason: "Expression evaluation timed out (>5s). "
                        + "Simplify the expressions or move heavy lifting into a support module.")
            } catch {
                throw WebAssignmentError.internalFailure(
                    reason: "Expression evaluator failed: \(error)")
            }
        }

        // Encode both lists for the manifest write.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let varData = try encoder.encode(body.variables)
        let exprData = try encoder.encode(expressions)
        guard let parsedVars = try JSONSerialization.jsonObject(with: varData) as? [Any],
            let parsedExprs = try JSONSerialization.jsonObject(with: exprData) as? [Any]
        else {
            throw WebAssignmentError.internalFailure(reason: "Failed to re-serialise section inputs.")
        }

        try await mutateManifest(setup: setup, on: req.db) { dict in
            guard var sections = dict["sections"] as? [[String: Any]] else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            guard let idx = sections.firstIndex(where: { ($0["id"] as? String) == sectionID }) else {
                throw WebAssignmentError.notFound(resource: "Section '\(sectionID)'")
            }
            if parsedVars.isEmpty {
                sections[idx].removeValue(forKey: "variables")
            } else {
                sections[idx]["variables"] = parsedVars
            }
            if parsedExprs.isEmpty {
                sections[idx].removeValue(forKey: "expressions")
            } else {
                sections[idx]["expressions"] = parsedExprs
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

    /// Build the 303 redirect back to the assignment edit page using the
    /// request's `:assignmentID` parameter, so the browser reloads into a
    /// freshly-rendered view of the new section state.
    private func redirectToEdit(req: Request) -> Response {
        let idStr = (try? assignmentPublicIDParameter(from: req)) ?? ""
        return req.redirect(to: "/instructor/\(idStr)/edit")
    }
}
