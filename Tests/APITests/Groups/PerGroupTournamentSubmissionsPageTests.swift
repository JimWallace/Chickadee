// Tests/APITests/Groups/PerGroupTournamentSubmissionsPageTests.swift
//
// The tournament section of GET /instructor/:assignmentID/submissions for an
// activity that runs once per lab group (docs/lab-groups.md, slice 3d):
//
//   - with lab groups, the run control offers each group, says who enters,
//     and asks before it supersedes only once a lab's run is in progress
//   - with no lab groups, the section says so, links to the Groups tab, and
//     offers no run control

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class PerGroupTournamentSubmissionsPageTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-submissions-pergroup")
    }

    /// The submissions page body, as the course instructor `username` reads it.
    private func submissionsPage(assignmentID: UUID, courseCode: String, username: String) async throws -> String {
        let cookie = try await loginAsCourseInstructor(username: username, courseCode: courseCode, on: app)
        let assignment = try #require(try await APIAssignment.find(assignmentID, on: app.db))
        var body = ""
        try await app.asyncTest(
            .GET, "/instructor/\(assignment.publicID)/submissions",
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                body = res.body.string
            })
        return body
    }

    @Test func theRunControlOffersEachLabGroup() async throws {
        try await withApp(app) { _ in
            let f = try await PerGroupActivityFixture.make(
                on: app, code: "SPG1", setupID: "spg_setup_groups",
                activity: ClassActivity(kind: .elimination, runsPerGroup: true),
                students: [("spg_ada", .a), ("spg_alan", .b)], withSubmissions: true)

            let body = try await submissionsPage(
                assignmentID: f.assignmentID, courseCode: "SPG1", username: "spg_instructor")
            #expect(body.contains("Each lab group plays its own tournament."))
            #expect(body.contains(#"action="/instructor/"#) && body.contains("/tournament/run"))
            #expect(body.contains(#"name="group""#), "a per-group run names its lab group")
            #expect(body.contains(#"value="\#(f.labA.uuidString)">Lab 101</option>"#))
            #expect(body.contains(#"value="\#(f.labB.uuidString)">Lab 102</option>"#))
            #expect(body.contains("session enter, seeded in submission order."))
            #expect(!body.contains("latest complete submission enters"))
            #expect(!body.contains("This course has no lab groups yet"))
            #expect(!body.contains("chosen group"), "no run is in progress, so the form does not ask")
        }
    }

    @Test func aLabsRunInProgressMakesTheFormAskBeforeSuperseding() async throws {
        try await withApp(app) { _ in
            let f = try await PerGroupActivityFixture.make(
                on: app, code: "SPG2", setupID: "spg_setup_running",
                activity: ClassActivity(kind: .elimination, runsPerGroup: true),
                students: [("spg_bea", .a), ("spg_bo", .a)], withSubmissions: true)
            for student in f.students {
                try await f.join(student, to: f.labA, on: app.db)
            }
            _ = try await startTournament(
                setup: f.setup, schedule: .bracket, startedBy: nil, groupID: f.labA, on: app.db)

            let body = try await submissionsPage(
                assignmentID: f.assignmentID, courseCode: "SPG2", username: "spg_instructor2")
            #expect(body.contains("data-confirm="))
            #expect(body.contains("A run in progress for the chosen group is superseded"))
            #expect(body.contains(#"name="group""#))
        }
    }

    @Test func aCourseWithNoLabGroupsGetsALinkToTheGroupsTabAndNoRunControl() async throws {
        try await withApp(app) { _ in
            let scenario = try await TestScenario.make(
                on: app, code: "SPG3", mode: .closed, setupID: "spg_setup_nogroups",
                properties: TestProperties(
                    testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
                    activity: ClassActivity(kind: .elimination, runsPerGroup: true)))

            let body = try await submissionsPage(
                assignmentID: scenario.assignmentID, courseCode: "SPG3", username: "spg_instructor3")
            #expect(body.contains("Tournament"))
            #expect(body.contains("This course has no lab groups yet; "))
            #expect(body.contains(#"<a href="/instructor/groups">add them on the Groups tab</a>"#))
            #expect(!body.contains("/tournament/run"), "no group can play, so there is no run control")
            #expect(!body.contains("Run tournament"))
            #expect(!body.contains("Each lab group plays its own tournament."))
            #expect(body.contains("/testsetups/spg_setup_nogroups/leaderboard"), "the bracket link stays")
        }
    }
}
