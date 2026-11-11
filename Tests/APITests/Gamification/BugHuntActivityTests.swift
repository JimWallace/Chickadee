// Tests/APITests/Gamification/BugHuntActivityTests.swift
//
// The bug-hunt kind (docs/bug-hunt-code-map.md): what `set_activity` seeds
// and refuses, how coverage is read through the suite, and the projector's
// board with and without a code map.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct BugHuntActivityTests {

    /// A gate every bug's entry depends on, and two bugs.
    private let suite = [
        TestSuiteEntry(tier: .pub, script: "publictest_wellformed.py", name: "Your tests pass"),
        TestSuiteEntry(
            tier: .pub, script: "publictest_bug_01.py", name: "Bug 1", dependsOn: ["publictest_wellformed.py"]),
        TestSuiteEntry(
            tier: .pub, script: "publictest_bug_02.py", name: "Bug 2", dependsOn: ["publictest_wellformed.py"]),
    ]

    private let code = "def bp(s):\n    if s <= 120:\n        return 'Normal'\n    return 'High'\n"

    private func manifestJSON(activity: ClassActivity? = nil) throws -> String {
        let props = TestProperties(testSuites: suite, language: .python, activity: activity)
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func seedAssignment(on app: Application) async throws -> APIAssignment {
        try await seedMCPAssignment(
            on: app, setupID: "setup_hunt", manifest: try manifestJSON(), courseCode: "HLTH230",
            courseName: "Health Data", title: "Bug Hunt 1")
    }

    private func storedActivity(on app: Application) async throws -> ClassActivity? {
        try #require(try await APITestSetup.find("setup_hunt", on: app.db)).decodedManifest()?.activity
    }

    private func input(
        _ assignment: APIAssignment, kind: String = "bugHunt", visibility: String? = nil, bugHunt: BugHuntSpec? = nil
    ) -> SetActivityTool.Input {
        SetActivityTool.Input(
            assignmentPublicID: assignment.publicID, kind: kind, leaderboardVisibility: visibility,
            bugHunt: bugHunt)
    }

    /// The seed is every entry nothing depends on: the bugs, not the gate.
    @Test func choosingTheKindSeedsTheEntriesNothingDependsOn() async throws {
        try await withTestApp { app in
            let assignment = try await seedAssignment(on: app)
            let out = try await SetActivityTool().execute(input(assignment), mcpContext(app))
            #expect(out.kind == "bugHunt")
            #expect(out.bugHunt == BugHuntSpec(items: ["publictest_bug_01.py", "publictest_bug_02.py"]))
            #expect(!out.recordAchievementSeeded, "a bug hunt seeds no record")

            let detail = try await GetAssignmentTool().execute(
                GetAssignmentTool.Input(assignmentPublicID: assignment.publicID), mcpContext(app))
            #expect(detail.activity?.aggregation == "coverage")
            #expect(detail.activity?.bugHunt == out.bugHunt)
        }
    }

    @Test func aGivenBlockIsStoredAndAnAbsentOneIsKept() async throws {
        try await withTestApp { app in
            let assignment = try await seedAssignment(on: app)
            let map = BugHuntSpec(
                items: ["publictest_bug_01.py"], code: code,
                regions: [BugHuntRegion(item: "publictest_bug_01.py", lines: "2-3")])
            _ = try await SetActivityTool().execute(input(assignment, bugHunt: map), mcpContext(app))
            #expect(try await storedActivity(on: app)?.bugHunt == map)

            let out = try await SetActivityTool().execute(input(assignment), mcpContext(app))
            #expect(out.bugHunt == map)
        }
    }

    @Test func anItemOutsideTheSuiteAndABlockOnAnotherKindAreRefused() async throws {
        try await withTestApp { app in
            let assignment = try await seedAssignment(on: app)
            await #expect(
                throws: MCPToolError.invalidArguments(
                    detail: ActivityAuthoring.bugHuntItemNotInSuiteMessage("bug_99.py"))
            ) {
                _ = try await SetActivityTool().execute(
                    input(assignment, bugHunt: BugHuntSpec(items: ["bug_99.py"])), mcpContext(app))
            }
            await #expect(throws: MCPToolError.self) {
                _ = try await SetActivityTool().execute(
                    input(assignment, kind: "bestMetric", bugHunt: BugHuntSpec(items: ["publictest_bug_01.py"])),
                    mcpContext(app))
            }
            #expect(try await storedActivity(on: app) == nil, "nothing was stored")
        }
    }

    /// A bug hunt's board is for the projector.
    @Test func theLeaderboardCannotBeShownToStudents() async throws {
        try await withTestApp { app in
            let assignment = try await seedAssignment(on: app)
            await #expect(
                throws: MCPToolError.invalidArguments(detail: ActivityAuthoring.bugHuntLeaderboardHiddenMessage)
            ) {
                _ = try await SetActivityTool().execute(input(assignment, visibility: "visible"), mcpContext(app))
            }
        }
    }

    /// Coverage rows carry the runner's outcome name (the display name), and
    /// the block names scripts; an entry that is not listed does not count.
    @Test func coverageIsReadThroughTheSuite() {
        let spec = BugHuntSpec(items: ["publictest_bug_01.py", "publictest_bug_02.py"])
        let coverage = BugHuntCoverage.make(
            spec: spec, suite: suite, coveredOutcomeNames: ["Bug 2", "Your tests pass"])
        #expect(coverage.coveredItems == ["publictest_bug_02.py"])
        #expect(coverage.percent == 50)
        #expect(BugHuntPresentation.make(spec: spec, coverage: coverage).countText == "1 of 2")
    }

    // MARK: - The projector

    /// A setup carrying `activity`, a logged-in instructor enrolled as staff,
    /// and one student. Returns the cookie and the student.
    private func seedBoard(activity: ClassActivity, id: String, on app: Application) async throws -> (String, APIUser) {
        _ = try await wrLoginAsStudent(on: app)
        let setup = try await wrInsertSetup(id: id, manifest: try manifestJSON(activity: activity), on: app)
        _ = try await makeTestAssignment(on: app, testSetupID: id, courseID: setup.courseID, title: "Hunt \(id)")
        let student = try await makeTestUser(on: app, username: "\(id)_s", role: "student")
        try await wrEnrollUser(student, on: app)
        let cookie = try await wrLoginAsInstructor(on: app)
        let instructor = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
        try await wrEnrollUser(instructor, on: app)
        return (cookie, student)
    }

    @Test func theProjectorLightsTheLinesOfACoveredItem() async throws {
        try await withWebRoutesApp { app in
            let spec = BugHuntSpec(
                items: ["publictest_bug_01.py", "publictest_bug_02.py"], code: code,
                regions: [
                    BugHuntRegion(item: "publictest_bug_01.py", lines: "2-3"),
                    BugHuntRegion(item: "publictest_bug_02.py", lines: "4"),
                ])
            let (cookie, student) = try await seedBoard(
                activity: ClassActivity(kind: .bugHunt, bugHunt: spec), id: "bh_map", on: app)
            let path = "/testsetups/bh_map/leaderboard?present=1&fragment=present"

            let before = try await getHTML(path, cookie: cookie, on: app)
            #expect(before.contains(">0%<"))
            #expect(before.components(separatedBy: "diff-uncovered").count - 1 == 3)
            #expect(!before.contains("diff-added"))

            try await APIClassItemCoverage(
                testSetupID: "bh_map", item: "Bug 1", userID: try student.requireID(), submissionID: "bh_sub"
            ).save(on: app.db)
            let after = try await getHTML(path, cookie: cookie, on: app)
            #expect(after.contains(">50%<"))
            #expect(after.components(separatedBy: "diff-added").count - 1 == 2)
            #expect(after.components(separatedBy: "diff-uncovered").count - 1 == 1)
            #expect(!after.contains(student.username), "the projector names nobody")
        }
    }

    /// With no code the board shows the share alone.
    @Test func withNoCodeTheProjectorShowsTheShareAlone() async throws {
        try await withWebRoutesApp { app in
            let spec = BugHuntSpec(items: ["publictest_bug_01.py", "publictest_bug_02.py"])
            let (cookie, _) = try await seedBoard(
                activity: ClassActivity(kind: .bugHunt, bugHunt: spec), id: "bh_pct", on: app)
            let page = try await getHTML("/testsetups/bh_pct/leaderboard?present=1", cookie: cookie, on: app)
            #expect(page.contains("bug-hunt-share"))
            #expect(page.contains("0 of 2 covered"))
            #expect(!page.contains("diff-table"))
            // The fixture has no starter notebook, so nothing records coverage.
            #expect(page.contains("no contribution slots"))

            let staffPage = try await getHTML("/testsetups/bh_pct/leaderboard", cookie: cookie, on: app)
            #expect(staffPage.contains("0 of 2 covered"))
        }
    }
}
