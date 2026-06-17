// Tests for the assignment-ordering MCP tool — reorder_assignments. Mirrors the
// web instructor dashboard's drag-reorder (POST /instructor/reorder): it writes
// the course-global APIAssignment.sortOrder from a full permutation of the
// course's assignment public IDs. Backed by a real test database.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct AssignmentOrderingToolsTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.write]
        )
    }

    /// Course + enrolled instructor.
    @discardableResult
    private func fixture(on app: Application) async throws -> APICourse {
        let course = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: course.requireID())
        return course
    }

    /// A published assignment with its own backing test setup.
    @discardableResult
    private func makeAssignment(
        on app: Application, setupID: String, title: String, courseID: UUID
    ) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID)
        return try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: title)
    }

    @Test func reordersAssignments() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let courseID = try course.requireID()
            let a = try await makeAssignment(on: app, setupID: "s_a", title: "A", courseID: courseID)
            let b = try await makeAssignment(on: app, setupID: "s_b", title: "B", courseID: courseID)
            let c = try await makeAssignment(on: app, setupID: "s_c", title: "C", courseID: courseID)

            let out = try await ReorderAssignmentsTool().execute(
                .init(
                    courseCode: "CS246",
                    orderedAssignmentPublicIDs: [c.publicID, a.publicID, b.publicID]),
                context(app))
            #expect(out.assignments.map(\.title) == ["C", "A", "B"])
            #expect(out.assignments.map(\.sortOrder) == [1, 2, 3])

            // Persisted course-global sortOrder reflects the new order.
            let reloadedC = try #require(try await APIAssignment.find(c.id, on: app.db))
            let reloadedA = try #require(try await APIAssignment.find(a.id, on: app.db))
            let reloadedB = try #require(try await APIAssignment.find(b.id, on: app.db))
            #expect(reloadedC.sortOrder == 1)
            #expect(reloadedA.sortOrder == 2)
            #expect(reloadedB.sortOrder == 3)
        }
    }

    @Test func reorderRejectsSubset() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let courseID = try course.requireID()
            let a = try await makeAssignment(on: app, setupID: "s_a", title: "A", courseID: courseID)
            _ = try await makeAssignment(on: app, setupID: "s_b", title: "B", courseID: courseID)

            // Only one of the two assignments — must be a full permutation.
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderAssignmentsTool().execute(
                    .init(courseCode: "CS246", orderedAssignmentPublicIDs: [a.publicID]),
                    context(app))
            }
        }
    }

    @Test func reorderRejectsDuplicateID() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await fixture(on: app)
            let courseID = try course.requireID()
            let a = try await makeAssignment(on: app, setupID: "s_a", title: "A", courseID: courseID)
            _ = try await makeAssignment(on: app, setupID: "s_b", title: "B", courseID: courseID)

            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderAssignmentsTool().execute(
                    .init(courseCode: "CS246", orderedAssignmentPublicIDs: [a.publicID, a.publicID]),
                    context(app))
            }
        }
    }

    @Test func reorderRejectsInvalidID() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderAssignmentsTool().execute(
                    .init(courseCode: "CS246", orderedAssignmentPublicIDs: ["not-a-valid-id"]),
                    context(app))
            }
        }
    }

    @Test func deniesUnenrolledCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            _ = try await fixture(on: app)  // tester enrolled only in CS246
            let other = try await makeTestCourse(on: app, code: "CS999", name: "Other")
            let foreign = try await makeAssignment(
                on: app, setupID: "s_x", title: "X", courseID: try other.requireID())

            await #expect(throws: MCPToolError.self) {
                _ = try await ReorderAssignmentsTool().execute(
                    .init(courseCode: "CS999", orderedAssignmentPublicIDs: [foreign.publicID]),
                    context(app))
            }
        }
    }
}
