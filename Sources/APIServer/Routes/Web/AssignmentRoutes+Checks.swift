// APIServer/Routes/Web/AssignmentRoutes+Checks.swift
//
// Notebook check editor endpoints.  Sibling to AssignmentRoutes+Families.swift
// for the parallel concept introduced in the data-science autograding
// roadmap (Tier-A onward).  PUT replaces the whole list atomically — the
// shared `applyPatternFamilies` save path takes the new checks alongside
// the existing families and rebuilds the test setup zip + manifest in one
// pass.

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    // MARK: - GET /instructor/:assignmentID/checks
    //
    // Returns the current list of NotebookCheck specs as a JSON array.
    // Counterpart to GET /families.

    @Sendable
    func getNotebookChecks(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        let checks: [NotebookCheck] = {
            guard let data = setup.manifest.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data)
            else { return [] }
            return props.notebookChecks
        }()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checks)
        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: data))
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
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        let checks: [NotebookCheck]
        do {
            checks = try req.content.decode([NotebookCheck].self)
        } catch {
            throw Abort(.badRequest,
                reason: "Invalid notebook check list: \(error.localizedDescription)")
        }

        // Carry forward the current families list — this endpoint only
        // edits checks.  The shared apply path validates and rewrites the
        // manifest with both lists in a single zip-mutation pass.
        let currentFamilies: [PatternFamily] = {
            guard let data = setup.manifest.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data)
            else { return [] }
            return props.patternFamilies
        }()

        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: currentFamilies,
            nextChecks: checks,
            on: req.db
        )

        await scheduleValidationAfterSuiteEdit(req: req, assignment: assignment)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(checks)
        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: data))
    }
}
