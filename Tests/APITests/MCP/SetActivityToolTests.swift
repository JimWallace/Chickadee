// Tests for SetActivityTool and the ActivityAuthoring core it shares with the
// web edit page. Backed by a real test database.
//
// The invariants: the kind is locked once a student has submitted, visibility
// is not; setting a leaderboard kind seeds one record on the highest metric
// without silencing the built-in records; clearing removes only what was
// seeded; and get_assignment reports what was stored.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct SetActivityToolTests {
    private func context(_ app: Application) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: "tester",
            grantedScopes: [.read, .write]
        )
    }

    private let workerManifest =
        #"{"schemaVersion":1,"gradingMode":"worker","testSuites":[],"timeLimitSeconds":10}"#

    private func fixture(on app: Application) async throws -> (APIAssignment, UUID) {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Programs")
        let courseID = try course.requireID()
        let tester = try await makeTestUser(on: app, username: "tester", role: "instructor")
        try await makeTestEnrollment(on: app, userID: tester.requireID(), courseID: courseID)
        try await makeTestSetup(on: app, id: "setup_act", courseID: courseID, manifest: workerManifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: "setup_act", courseID: courseID, title: "Tour race")
        return (assignment, courseID)
    }

    private func manifest(on app: Application) async throws -> TestProperties {
        let setup = try #require(try await APITestSetup.find("setup_act", on: app.db))
        return try #require(setup.decodedManifest())
    }

    @Test func setsAKindHiddenByDefaultAndSeedsTheRecord() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            let out = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: nil),
                context(app))
            #expect(out.kind == "bestMetric")
            #expect(out.leaderboardVisibility == "hidden")
            #expect(out.leaderboardPath == "/testsetups/setup_act/leaderboard")
            #expect(out.recordAchievementSeeded)

            let props = try await manifest(on: app)
            #expect(props.activity == ClassActivity(kind: .bestMetric))
            let records = props.achievements.filter { $0.recordDimension == .highestMetric }
            #expect(records.map(\.id) == [ActivityAuthoring.seededRecordID])
            // Seeding curated the built-ins alongside, so Pathfinder and
            // friends still award (a non-empty manifest list is authoritative).
            #expect(props.builtInAchievementsSeeded)
            for builtIn in BuiltInAchievements.classRecords {
                #expect(props.achievements.contains { $0.id == builtIn.id }, "\(builtIn.id)")
            }

            // get_assignment reports the block.
            let detail = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), context(app))
            #expect(detail.activity?.kind == "bestMetric")
            #expect(detail.activity?.leaderboardVisibility == "hidden")
            #expect(detail.activity?.leaderboardPath == out.leaderboardPath)
        }
    }

    @Test func settingTwiceSeedsOneRecordAndVisibilityChangesFreely() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            _ = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "beatTheInstructor", leaderboardVisibility: nil),
                context(app))
            let out = try await SetActivityTool().execute(
                .init(
                    assignmentPublicID: assignment.publicID, kind: "beatTheInstructor", leaderboardVisibility: "visible"
                ),
                context(app))
            #expect(out.leaderboardVisibility == "visible")
            let props = try await manifest(on: app)
            #expect(props.activity?.leaderboardVisibleToStudents == true)
            #expect(props.achievements.filter { $0.id == ActivityAuthoring.seededRecordID }.count == 1)
        }
    }

    @Test func kindIsLockedOnceAStudentHasSubmittedButVisibilityIsNot() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, courseID) = try await fixture(on: app)
            _ = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: nil),
                context(app))
            let student = try await makeTestStudent(on: app, username: "act_student")
            try await makeTestEnrollment(on: app, userID: student.requireID(), courseID: courseID)
            try await makeTestSubmission(
                on: app, id: "sub_act", setupID: "setup_act", userID: student.requireID())

            // Visibility still moves.
            let shown = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: "visible"),
                context(app))
            #expect(shown.leaderboardVisibility == "visible")

            // A different kind, and clearing, are both refused and leave the
            // stored block untouched.
            for locked in ["beatTheInstructor", "none"] {
                await #expect(throws: MCPToolError.self) {
                    _ = try await SetActivityTool().execute(
                        .init(assignmentPublicID: assignment.publicID, kind: locked, leaderboardVisibility: nil),
                        context(app))
                }
            }
            let props = try await manifest(on: app)
            #expect(props.activity == ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible))
        }
    }

    @Test func clearingRemovesTheBlockAndOnlyTheSeededRecord() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            _ = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: nil),
                context(app))
            let out = try await SetActivityTool().execute(
                .init(assignmentPublicID: assignment.publicID, kind: "none", leaderboardVisibility: nil),
                context(app))
            #expect(out.kind == "none")
            #expect(out.leaderboardVisibility == nil)
            #expect(out.leaderboardPath == nil)
            #expect(!out.recordAchievementSeeded)
            let props = try await manifest(on: app)
            #expect(props.activity == nil)
            #expect(!props.achievements.contains { $0.id == ActivityAuthoring.seededRecordID })
            // The curated built-ins stay: clearing an activity is not a reason
            // to un-curate the achievements table.
            #expect(props.achievements.contains { $0.id == BuiltInAchievements.pathfinder.id })
        }
    }

    @Test func rejectsAnUnknownKindOrVisibility() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let (assignment, _) = try await fixture(on: app)
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    .init(assignmentPublicID: assignment.publicID, kind: "tournament", leaderboardVisibility: nil),
                    context(app))
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    .init(assignmentPublicID: assignment.publicID, kind: "bestMetric", leaderboardVisibility: "public"),
                    context(app))
            }
            #expect(try await manifest(on: app).activity == nil)
        }
    }

    @Test func serverInfoListsEveryKind() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let out = try await GetServerInfoTool().execute(GetServerInfoTool.Input(), context(app))
            #expect(out.activityKinds.map(\.name) == ActivityKind.allCases.map(\.rawValue))
            for kind in out.activityKinds {
                #expect(!kind.summary.isEmpty)
                #expect(kind.aggregation == "leaderboard")
            }
        }
    }
}
