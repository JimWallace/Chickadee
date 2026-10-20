// Tests for SetAssignmentConceptTool (tag an assignment with the lab concept
// whose wardrobe ring full marks earn, or clear the tag), backed by a real test
// database: set and clear without closing, an unknown token refused, the
// `.instructor` role floor, enrollment, and the get_assignment read echo.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetAssignmentConceptToolTests {
    private let manifest =
        TestManifests.workerEmpty

    /// A live course + setup + assignment, with `tester` (a global user)
    /// enrolled at the given per-course role.
    private func fixture(
        on app: Application, role: CourseRole = .instructor, enroll: Bool = true
    ) async throws -> APIAssignment {
        let course = try await makeTestCourse(on: app, code: "CS115", name: "Intro")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "student")
        if enroll {
            try await APICourseEnrollment(userID: try tester.requireID(), courseID: courseID, role: role)
                .save(on: app.db)
        }
        try await makeTestSetup(on: app, id: "setup_concept", courseID: courseID, manifest: manifest)
        return try await makeTestAssignment(
            on: app, testSetupID: "setup_concept", courseID: courseID, title: "Loops Lab")
    }

    private func storedConcept(of assignment: APIAssignment, on app: Application) async throws -> AssignmentConcept? {
        try #require(try await APIAssignment.find(assignment.id, on: app.db)).concept
    }

    @Test func setsAndClearsWithoutClosing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            #expect(assignment.visibility == .open)

            let set = try await SetAssignmentConceptTool().execute(
                .init(assignmentPublicID: assignment.publicID, concept: "loops"), mcpContext(app))
            #expect(set.concept == "loops")
            #expect(set.ring == "Ouroboros")
            #expect(try await storedConcept(of: assignment, on: app) == .loops)
            // A cosmetic tag: the assignment stays open.
            #expect(try #require(try await APIAssignment.find(assignment.id, on: app.db)).visibility == .open)

            let cleared = try await SetAssignmentConceptTool().execute(
                .init(assignmentPublicID: assignment.publicID, concept: "none"), mcpContext(app))
            #expect(cleared.concept == nil)
            #expect(cleared.ring == nil)
            #expect(try await storedConcept(of: assignment, on: app) == nil)
        }
    }

    @Test func refusesAnUnknownConceptAndChangesNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            _ = try await SetAssignmentConceptTool().execute(
                .init(assignmentPublicID: assignment.publicID, concept: "binary"), mcpContext(app))
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentConceptTool().execute(
                    .init(assignmentPublicID: assignment.publicID, concept: "recursion"), mcpContext(app))
            }
            #expect(try await storedConcept(of: assignment, on: app) == .binary)
        }
    }

    @Test func deniesTABelowInstructorFloor() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, role: .ta)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentConceptTool().execute(
                    .init(assignmentPublicID: assignment.publicID, concept: "loops"), mcpContext(app))
            }
            #expect(try await storedConcept(of: assignment, on: app) == nil)
        }
    }

    @Test func deniesAnUnenrolledCaller() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app, enroll: false)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetAssignmentConceptTool().execute(
                    .init(assignmentPublicID: assignment.publicID, concept: "loops"), mcpContext(app))
            }
        }
    }

    @Test func getAssignmentEchoesTheConcept() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let assignment = try await fixture(on: app)
            let before = try await GetAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(before.concept == nil)

            _ = try await SetAssignmentConceptTool().execute(
                .init(assignmentPublicID: assignment.publicID, concept: "healthData"), mcpContext(app))
            let after = try await GetAssignmentTool().execute(
                .init(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(after.concept == "healthData")
        }
    }

    /// The schema offers every concept and the clearing token, and nothing else.
    @Test func theSchemaListsEveryConcept() throws {
        let expected = AssignmentConcept.allCases.map(\.rawValue) + [SetAssignmentConceptTool.noneToken]
        #expect(MCPEnumProse<AssignmentConcept>.tokens + ["none"] == expected)
        for concept in AssignmentConcept.allCases {
            #expect(SetAssignmentConceptTool.description.contains(concept.rawValue))
        }
    }
}
