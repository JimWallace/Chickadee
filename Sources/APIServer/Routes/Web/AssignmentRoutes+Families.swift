// APIServer/Routes/Web/AssignmentRoutes+Families.swift
//
// Pattern family editor endpoints.  The canonical spec for a family lives in
// the test setup manifest (TestProperties.patternFamilies); these endpoints
// are the single editing surface for that spec.  PUT replaces the whole list
// atomically — validation, zip mutation, and manifest rewrite all happen in
// `applyPatternFamilies`.

import Vapor
import Fluent
import Core
import Foundation

extension AssignmentRoutes {

    // MARK: - GET /instructor/:assignmentID/families
    //
    // Returns the current list of PatternFamily specs as a JSON array.  Used
    // by the editor JS to seed its in-page state if the page context wasn't
    // enough (e.g. after a save, to refresh).

    @Sendable
    func getPatternFamilies(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        let families: [PatternFamily] = {
            guard let data = setup.manifest.data(using: .utf8),
                  let props = try? JSONDecoder().decode(TestProperties.self, from: data)
            else { return [] }
            return props.patternFamilies
        }()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(families)
        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: data))
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
        let user = try req.auth.require(APIUser.self)
        guard user.isInstructor else { throw Abort(.forbidden) }

        let idStr = try assignmentPublicIDParameter(from: req)
        guard
            let assignment = try await assignmentByPublicID(idStr, on: req.db),
            let setup      = try await APITestSetup.find(assignment.testSetupID, on: req.db)
        else { throw Abort(.notFound) }

        let families: [PatternFamily]
        do {
            families = try req.content.decode([PatternFamily].self)
        } catch {
            throw Abort(.badRequest,
                reason: "Invalid pattern family list: \(error.localizedDescription)")
        }

        _ = try await applyPatternFamilies(
            to: setup,
            nextFamilies: families,
            on: req.db
        )

        // Return the applied list so the client can reconcile state without
        // a second round-trip.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(families)
        return Response(status: .ok,
                        headers: ["Content-Type": "application/json"],
                        body: .init(data: data))
    }
}
