// Tests/APITests/Courses/AssignmentTypeColumnTests.swift
//
// The declared assignment type on the `assignments` row
// (docs/assignment-types.md): the MCP read and write, and the row tile each
// type draws.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct AssignmentTypeColumnTests {

    private static let workerManifest = #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[]}"#

    private func untypedAssignment(
        on app: Application, setupID: String, manifest: String, courseID: UUID
    ) async throws -> APIAssignment {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: setupID)
        #expect(assignment.assignmentTypeRaw == nil)
        return assignment
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
                    assignmentPublicID: assignment.publicID, assignmentType: "lab"),
                mcpContext(app))
            #expect(output.assignmentType == "lab")
            let read = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(read.assignmentType == "lab")

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
