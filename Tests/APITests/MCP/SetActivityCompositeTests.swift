// Tests/APITests/MCP/SetActivityCompositeTests.swift
//
// The class-composite kind through `set_activity` and the `ActivityAuthoring`
// core it shares with the web edit page (docs/class-composite.md, slice 2):
// the starter block, carrying the block forward, the save rules, the
// projector-only leaderboard, and the structure lock under live submissions.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetActivityCompositeTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: makeTestRequest(on: app),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private let workerManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","language":"python","testSuites":[],"timeLimitSeconds":10}"#

    private func fixture(on app: Application) async throws -> (APIAssignment, UUID) {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_cmp", courseID: courseID, manifest: workerManifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_cmp", courseID: courseID, title: "Class GPU")
        return (assignment, courseID)
    }

    private func storedActivity(on app: Application) async throws -> ClassActivity? {
        let setup = try #require(try await APITestSetup.find("setup_cmp", on: app.db))
        return setup.decodedManifest()?.activity
    }

    private func input(
        _ assignment: APIAssignment, kind: String = "classComposite", visibility: String? = nil,
        composite: CompositeSpec? = nil
    ) -> SetActivityTool.Input {
        SetActivityTool.Input(
            assignmentPublicID: assignment.publicID, kind: kind, leaderboardVisibility: visibility,
            composite: composite)
    }

    private let sequence = CompositeSpec(
        compositor: .sequence, layout: .count(24),
        contribution: CompositeContributionShape(width: 16, height: 16, frames: 1, format: .gray8),
        frameRate: 8)

    @Test func choosingTheKindWithoutABlockSeedsTheStarter() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            let out = try await SetActivityTool().execute(input(assignment), context(app))
            #expect(out.kind == "classComposite")
            #expect(out.composite == .starter)
            #expect(out.opponentSource == "none")
            #expect(!out.recordAchievementSeeded, "a composite seeds no record")
            #expect(try await storedActivity(on: app)?.composite == .starter)

            let detail = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(detail.activity?.aggregation == "composite")
            #expect(detail.activity?.composite == .starter)
        }
    }

    @Test func aGivenBlockIsStoredAndAnAbsentOneIsKept() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            _ = try await SetActivityTool().execute(input(assignment, composite: sequence), context(app))
            #expect(try await storedActivity(on: app)?.composite == sequence)

            // A call that names only the kind keeps the stored block.
            let out = try await SetActivityTool().execute(input(assignment), context(app))
            #expect(out.composite == sequence)
        }
    }

    @Test func aBlockOnAnotherKindIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    input(assignment, kind: "bestMetric", composite: sequence), context(app))
            }
            #expect(try await storedActivity(on: app) == nil, "nothing was stored")
        }
    }

    @Test func aBlockThatBreaksARuleIsRefused() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            let wrongShape = CompositeSpec(
                compositor: .tile, layout: .count(12), contribution: sequence.contribution)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(input(assignment, composite: wrongShape), context(app))
            }
            #expect(try await storedActivity(on: app) == nil)
        }
    }

    /// The composite is for the projector; each student sees only their own
    /// contribution, so the leaderboard page cannot be shown to students.
    @Test func theLeaderboardCannotBeShownToStudents() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(input(assignment, visibility: "visible"), context(app))
            }
            _ = try await SetActivityTool().execute(input(assignment), context(app))
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(input(assignment, visibility: "visible"), context(app))
            }
            #expect(try await storedActivity(on: app)?.leaderboardVisibility == .hidden)
        }
    }

    @Test func theStructureLocksOnceAStudentHasSubmittedButDisplaySettingsDoNot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, courseID) = try await fixture(on: app)
            _ = try await SetActivityTool().execute(input(assignment, composite: sequence), context(app))
            let student = try await makeTestStudent(on: app, username: "cmp_student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)
            try await makeTestSubmission(
                on: app, id: "sub_cmp", setupID: "setup_cmp", userID: student.requireID())

            let display = sequence.withDisplay(frameRate: 24, showFailed: false, emptySlots: .reference)
            let out = try await SetActivityTool().execute(input(assignment, composite: display), context(app))
            #expect(out.composite == display)

            let moreSlots = CompositeSpec(
                compositor: .sequence, layout: .count(30), contribution: sequence.contribution)
            await #expect(
                throws: MCPToolError.invalidArguments(detail: ActivityAuthoring.compositeLayoutLockedMessage)
            ) {
                _ = try await SetActivityTool().execute(input(assignment, composite: moreSlots), context(app))
            }
            #expect(try await storedActivity(on: app)?.composite == display)
        }
    }
}
