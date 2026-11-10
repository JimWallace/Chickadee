// Tests/APITests/Courses/AssignmentTypeColumnTests.swift
//
// The declared assignment type on the `assignments` row
// (docs/assignment-types.md): the one-time backfill, the MCP read and write,
// and the row tile each type draws.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct AssignmentTypeColumnTests {

    private static let browserManifest = #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[]}"#
    private static let workerManifest = #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[]}"#
    private static let activityManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"activity":{"kind":"bestMetric"}}"#
    private static let browserActivityManifest =
        #"{"schemaVersion":1,"gradingMode":"browser","testSuites":[],"activity":{"kind":"bestMetric"}}"#

    private func untypedAssignment(
        on app: Application, setupID: String, manifest: String, courseID: UUID
    ) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: setupID)
        #expect(assignment.assignmentTypeRaw == nil)
        return assignment
    }

    @Test func theBackfillRecordsATypeFromEachManifest() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "HLTH230", name: "Health").requireID()
            let assignment = try await untypedAssignment(
                on: app, setupID: "setup_type_a", manifest: Self.workerManifest, courseID: courseID)
            let lab = try await untypedAssignment(
                on: app, setupID: "setup_type_lab", manifest: Self.browserManifest,
                courseID: courseID)
            let labWithActivity = try await untypedAssignment(
                on: app, setupID: "setup_type_lab4b", manifest: Self.browserActivityManifest,
                courseID: courseID)
            let activity = try await untypedAssignment(
                on: app, setupID: "setup_type_act", manifest: Self.activityManifest, courseID: courseID)
            // A row that already declares a type keeps it.
            let declared = try await untypedAssignment(
                on: app, setupID: "setup_type_declared", manifest: Self.workerManifest, courseID: courseID)
            declared.assignmentType = .lab
            try await declared.save(on: app.db)

            try await BackfillAssignmentType().prepare(on: app.db)

            func reloaded(_ row: APIAssignment) async throws -> String? {
                let stored = try await assignmentByPublicID(row.publicID, on: app.db)
                return try #require(stored).assignmentTypeRaw
            }
            #expect(try await reloaded(assignment) == "assignment")
            #expect(try await reloaded(lab) == "lab")
            #expect(try await reloaded(labWithActivity) == "lab")
            #expect(try await reloaded(activity) == "classActivity")
            #expect(try await reloaded(declared) == "lab")
        }
    }

    @Test func updateAssignmentSetsTheTypeAndGetAssignmentReportsIt() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CS246", name: "OOP").requireID()
            let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
            try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
            let assignment = try await untypedAssignment(
                on: app, setupID: "setup_type_mcp", manifest: Self.workerManifest, courseID: courseID)

            let output = try await UpdateAssignmentTool().execute(
                UpdateAssignmentTool.Input(
                    assignmentPublicID: assignment.publicID, assignmentType: "classActivity"),
                mcpContext(app))
            #expect(output.assignmentType == "classActivity")
            let read = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(read.assignmentType == "classActivity")

            await #expect(throws: MCPToolError.self) {
                _ = try await UpdateAssignmentTool().execute(
                    UpdateAssignmentTool.Input(assignmentPublicID: assignment.publicID, assignmentType: "quiz"),
                    mcpContext(app))
            }
        }
    }

    @Test(arguments: [
        (AssignmentType.assignment, "graded", "i-clipboard-check"),
        (AssignmentType.lab, "lab", "i-flask"),
        (AssignmentType.classActivity, "activity", "i-users"),
    ])
    func eachTypeDrawsItsOwnTile(type: AssignmentType, kind: String, symbol: String) {
        let html = AssignmentTypeTile(type: type).render()
        #expect(html.contains(#"data-kind="\#(kind)""#))
        #expect(html.contains("#\(symbol)"))
    }
}
