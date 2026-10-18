// Tests/APITests/Groups/LeaderboardPerGroupTests.swift
//
// A leaderboard activity run once per lab group (docs/lab-groups.md, slice
// 3a): a ranked row goes to the group of the session the student had joined
// when they submitted; a submission made with no session open, or by a
// student who never joined, grades and does not rank; a student ranks in each
// lab they play, and an older course-wide row blocks nothing; each group reads
// its own board, on the page and on the projector, and a student reads only
// their own; and the kinds that do not rank per group yet refuse the flag.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LeaderboardPerGroupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-leaderboard-groups")
    }

    private struct Fixture {
        let courseID: UUID
        let assignmentID: UUID
        let labA: UUID
        let labB: UUID
        let ada: UUID
        let alan: UUID
        let grace: UUID
    }

    private let setupID = "lbg_setup"

    /// A per-group best-metric activity with Lab 101 (ada) and Lab 102 (alan);
    /// grace is in no group.
    private func fixture(on app: Application) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "LBG1", mode: .closed)
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
            activity: ClassActivity(kind: .bestMetric, leaderboardVisibility: .visible, runsPerGroup: true))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        var students: [UUID] = []
        for name in ["lbg_ada", "lbg_alan", "lbg_grace"] {
            let id = try await makeTestStudent(on: app, username: name).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            students.append(id)
        }
        try await CourseGroupStore.setMembership(userID: students[0], groupID: labA, in: set, on: app.db)
        try await CourseGroupStore.setMembership(userID: students[1], groupID: labB, in: set, on: app.db)
        return Fixture(
            courseID: courseID, assignmentID: try assignment.requireID(), labA: labA, labB: labB,
            ada: students[0], alan: students[1], grace: students[2])
    }

    private func outcome(metric: Double) -> TestOutcome {
        TestOutcome(
            testName: "match", testClass: nil, tier: .pub, status: .pass, shortResult: "passed", longResult: nil,
            metric: metric, executionTimeMs: 1, memoryUsageBytes: nil, attemptNumber: 1, isFirstPassSuccess: false)
    }

    /// Opens the group's session a minute ago and joins `userID` to it.
    @discardableResult
    private func joinSession(_ f: Fixture, group: UUID, userID: UUID) async throws -> APIActivitySession {
        let session = try await ActivitySessionStore.open(
            assignmentID: f.assignmentID, groupID: group, by: nil, now: Date().addingTimeInterval(-60), on: app.db)
        let joinedAt = Date().addingTimeInterval(-30)
        try await ActivitySessionStore.join(
            code: ActivitySessionCode.code(secret: session.codeSecret, at: joinedAt), userID: userID,
            now: joinedAt, on: app.db)
        return session
    }

    /// Moves `userID` to `group`, as a TA does on the Groups tab: a member
    /// joins only their own lab's session.
    private func move(_ userID: UUID, to group: UUID) async throws {
        let groupRow = try #require(try await APICourseGroup.find(group, on: app.db))
        let set = try #require(try await APICourseGroupSet.find(groupRow.setID, on: app.db))
        try await CourseGroupStore.setMembership(userID: userID, groupID: group, in: set, on: app.db)
    }

    /// Makes a submission now and records its metric, as result ingest does.
    private func submit(_ userID: UUID, id: String, metric: Double) async throws {
        _ = try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: userID)
        try await recordLeaderboardEntry(
            testSetupID: setupID, userID: userID, submissionID: id, outcomes: [outcome(metric: metric)], on: app.db)
    }

    /// The student's row on one group's board.
    private func entry(_ userID: UUID, in group: UUID) async throws -> APIGroupLeaderboardEntry? {
        try await APIGroupLeaderboardEntry.query(on: app.db)
            .filter(\.$testSetupID == setupID)
            .filter(\.$groupID == group)
            .filter(\.$userID == userID)
            .first()
    }

    // MARK: - Ingest

    @Test func aRankedRowCarriesTheGroupOfTheSessionTheStudentJoined() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(on: app)
            try await joinSession(f, group: f.labA, userID: f.ada)
            // grace is in no group and joins Lab 102's session by code.
            try await joinSession(f, group: f.labB, userID: f.grace)
            try await submit(f.ada, id: "lbg_s1", metric: 5)
            try await submit(f.grace, id: "lbg_s2", metric: 7)
            #expect(try await entry(f.ada, in: f.labA)?.metric == 5)
            #expect(try await entry(f.grace, in: f.labB)?.metric == 7)
            #expect(try await entry(f.ada, in: f.labB) == nil)
        }
    }

    @Test func aSubmissionWithNoSessionGradesAndDoesNotRank() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(on: app)
            // alan is a member of Lab 102 but never joined its open session.
            try await ActivitySessionStore.open(assignmentID: f.assignmentID, groupID: f.labB, by: nil, on: app.db)
            try await submit(f.alan, id: "lbg_s3", metric: 9)
            #expect(try await entry(f.alan, in: f.labB) == nil, "membership alone does not rank")

            // ada joined, and the session closed before ada submitted.
            let session = try await joinSession(f, group: f.labA, userID: f.ada)
            try await ActivitySessionStore.close(session, now: Date().addingTimeInterval(-1), on: app.db)
            try await submit(f.ada, id: "lbg_s4", metric: 9)
            #expect(try await entry(f.ada, in: f.labA) == nil, "the board froze when the session closed")
        }
    }

    @Test func aStudentRanksInEachLabTheyPlayAndAnOlderRowBlocksNothing() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(on: app)
            // A best from before the activity ran per group.
            try await APILeaderboardEntry(
                testSetupID: setupID, userID: f.ada, submissionID: "lbg_old", metric: 50, reachedAt: Date()
            ).save(on: app.db)
            try await joinSession(f, group: f.labA, userID: f.ada)
            try await submit(f.ada, id: "lbg_s7", metric: 5)
            try await move(f.ada, to: f.labB)
            try await joinSession(f, group: f.labB, userID: f.ada)
            try await submit(f.ada, id: "lbg_s8", metric: 3)
            #expect(try await entry(f.ada, in: f.labA)?.metric == 5, "the older, higher row does not block it")
            #expect(try await entry(f.ada, in: f.labB)?.metric == 3, "a second lab is a second board")
        }
    }

    @Test func aJoinAfterTheSubmissionDoesNotMoveIt() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(on: app)
            try await joinSession(f, group: f.labA, userID: f.ada)
            _ = try await makeTestSubmission(on: app, id: "lbg_s9", setupID: setupID, userID: f.ada)
            try await move(f.ada, to: f.labB)
            // ada joins Lab 102 after submitting, before the result is graded.
            let labB = try await ActivitySessionStore.open(
                assignmentID: f.assignmentID, groupID: f.labB, by: nil, now: Date().addingTimeInterval(-60),
                on: app.db)
            let later = Date().addingTimeInterval(5)
            try await ActivitySessionStore.join(
                code: ActivitySessionCode.code(secret: labB.codeSecret, at: later), userID: f.ada, now: later,
                on: app.db)
            try await recordLeaderboardEntry(
                testSetupID: setupID, userID: f.ada, submissionID: "lbg_s9", outcomes: [outcome(metric: 4)],
                on: app.db)
            #expect(try await entry(f.ada, in: f.labA)?.metric == 4, "ranked in the lab it was played in")
            #expect(try await entry(f.ada, in: f.labB) == nil)
        }
    }

    @Test func reEnteringTheSameCodeDuringGradingKeepsThePlace() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(on: app)
            let labA = try await joinSession(f, group: f.labA, userID: f.ada)
            _ = try await makeTestSubmission(on: app, id: "lbg_s10", setupID: setupID, userID: f.ada)
            // ada types Lab 101's code again before the result is graded.
            let later = Date().addingTimeInterval(5)
            try await ActivitySessionStore.join(
                code: ActivitySessionCode.code(secret: labA.codeSecret, at: later), userID: f.ada, now: later,
                on: app.db)
            try await recordLeaderboardEntry(
                testSetupID: setupID, userID: f.ada, submissionID: "lbg_s10", outcomes: [outcome(metric: 6)],
                on: app.db)
            #expect(try await entry(f.ada, in: f.labA)?.metric == 6)
        }
    }

    // MARK: - Reading

    @Test func eachGroupReadsItsOwnBoard() async throws {
        try await withApp(app) { app in
            let f = try await fixture(on: app)
            try await joinSession(f, group: f.labA, userID: f.ada)
            try await joinSession(f, group: f.labB, userID: f.alan)
            try await submit(f.ada, id: "lbg_s5", metric: 5)
            try await submit(f.alan, id: "lbg_s6", metric: 7)

            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            let staff = try await makeTestUser(on: app, username: "lbg_ta", role: "student")
            try await APICourseEnrollment(userID: staff.requireID(), courseID: f.courseID, role: .ta).save(on: app.db)
            let reader = LeaderboardReader.page(user: staff, isStaff: true)
            let labA = try await buildLeaderboard(
                setup: setup, reader: reader, showAll: true, groupID: f.labA, on: app.db)
            let labB = try await buildLeaderboard(
                setup: setup, reader: reader, showAll: true, groupID: f.labB, on: app.db)
            #expect(labA.rows.map(\.username) == ["lbg_ada"])
            #expect(labB.rows.map(\.username) == ["lbg_alan"])

            let taCookie = try await loginUser(username: "lbg_ta", password: "pw", role: "student", on: app)
            let pageB = try await getHTML(
                "/testsetups/\(setupID)/leaderboard?group=\(f.labB.uuidString)", cookie: taCookie, on: app)
            #expect(pageB.contains("lbg_alan") && !pageB.contains("lbg_ada"), "staff pick a group's board")
            #expect(pageB.contains("Lab group"), "staff read a group picker")

            let present = try await getHTML(
                "/testsetups/\(setupID)/leaderboard?present=1&group=\(f.labA.uuidString)", cookie: taCookie,
                on: app)
            #expect(present.contains("group=\(f.labA.uuidString)"), "the projector refreshes the same group")

            let adaCookie = try await loginUser(username: "lbg_ada", password: "pw", role: "student", on: app)
            let studentPage = try await getHTML("/testsetups/\(setupID)/leaderboard", cookie: adaCookie, on: app)
            #expect(studentPage.contains("Lab 101"), "a student reads their own group's board")
            let asked = try await getHTML(
                "/testsetups/\(setupID)/leaderboard?group=\(f.labB.uuidString)", cookie: adaCookie, on: app)
            #expect(!asked.contains("Lab 102"), "a student cannot read another group's board")
        }
    }

    // MARK: - Authoring

    @Test(arguments: [ActivityKind.roundRobin, .testsVersusImplementations])
    func aKindThatDoesNotRankPerGroupRefusesTheFlag(kind: ActivityKind) async throws {
        try await withApp(app) { app in
            _ = try await fixture(on: app)
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            let error = await #expect(throws: AppError.self) {
                try await ActivityAuthoring.setActivity(
                    setup: setup, to: ClassActivity(kind: kind, runsPerGroup: true), on: app.db)
            }
            #expect(error?.reason == ActivityAuthoring.runsPerGroupKindMessage)
        }
    }
}
