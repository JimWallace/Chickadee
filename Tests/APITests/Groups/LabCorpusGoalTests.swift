// Tests/APITests/Groups/LabCorpusGoalTests.swift
//
// Coverage goals of an activity that runs once per lab group
// (docs/lab-groups.md, slice 5c): a lab's corpus holds only its own students
// and is debounced on its own; a student's result schedules the run of the
// lab of the session they submitted in, and none without one, and on a
// whole-class activity the class's run; each lab's coverage goal reads its
// own latest run, never the whole class's; and course delete removes the
// lab runs.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LabCorpusGoalTests {

    private func notebookJSON(cells: [String]) -> String {
        """
        {"cells":[\(cells.joined(separator: ","))],"metadata":{"kernelspec":{"name":"xpython"}},\
        "nbformat":4,"nbformat_minor":5}
        """
    }

    private func slotCell(_ source: String, slot: String) -> String {
        """
        {"cell_type":"code","metadata":{"chickadee_slot":"\(slot)"},\
        "source":"\(source)","outputs":[],"execution_count":null}
        """
    }

    private func testCell(_ source: String) -> String {
        """
        {"cell_type":"code","metadata":{},"source":"# TEST: tier=public\\n\(source)",\
        "outputs":[],"execution_count":null}
        """
    }

    private struct Fixture {
        let setupID: String
        let assignmentID: UUID
        let labA: UUID
        let labB: UUID
        /// In Lab 101.
        let ada: APIUser
        /// In Lab 102.
        let alan: APIUser
        /// In no session.
        let grace: APIUser
    }

    /// A per-group bug hunt with two slots and a coverage goal, two labs, and
    /// one student in each lab's open session; with `runsPerGroup` off, the
    /// same bug hunt for the whole class, with no session.
    private func fixture(_ app: Application, runsPerGroup: Bool = true) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let setupID = "lcorp_setup"
        let starter = notebookJSON(cells: [
            slotCell("# first test", slot: "1"), slotCell("# second test", slot: "2"),
            testCell("assert well_formed()"),
        ])
        let notebookPath = app.testSetupsDirectory + "\(setupID).ipynb"
        try Data(starter.utf8).write(to: URL(fileURLWithPath: notebookPath))
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "test_corpus.sh")],
            language: nil,
            activity: ClassActivity(kind: .bestMetric, runsPerGroup: runsPerGroup),
            achievements: [
                Achievement(
                    id: "cov", name: "Lab coverage", scope: .classWide,
                    conditions: [AchievementCondition(signal: .classCoverage, comparator: .atLeast, value: 80)],
                    reward: AchievementReward(type: .points, label: "Coverage", points: 2),
                    classFraction: 1)
            ])
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        try await APITestSetup(
            id: setupID, manifest: manifest, zipPath: app.testSetupsDirectory + "\(setupID).zip",
            notebookPath: notebookPath, courseID: courseID
        ).save(on: app.db)
        let assignmentID = try await arInsertAssignment(
            testSetupID: setupID, title: "Lab bug hunt", isOpen: true, on: app
        ).requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()

        var users: [APIUser] = []
        for (name, lab) in [("lcorp_ada", labA), ("lcorp_alan", labB), ("lcorp_grace", nil)] {
            let user = try await arInsertStudent(username: name, on: app)
            try await arEnrollStudentInTestCourse(user, on: app)
            if runsPerGroup, let lab {
                let session = try await ActivitySessionStore.open(
                    assignmentID: assignmentID, groupID: lab, by: nil, now: Date().addingTimeInterval(-60),
                    on: app.db)
                let joinedAt = Date().addingTimeInterval(-30)
                try await ActivitySessionStore.join(
                    code: ActivitySessionCode.code(secret: session.codeSecret, at: joinedAt),
                    userID: try user.requireID(), now: joinedAt, on: app.db)
            }
            users.append(user)
        }
        return Fixture(
            setupID: setupID, assignmentID: assignmentID, labA: labA, labB: labB, ada: users[0], alan: users[1],
            grace: users[2])
    }

    /// A submission of `slots`, stored as the submit path stores it.
    @discardableResult
    private func submit(_ app: Application, _ f: Fixture, user: APIUser, id: String) async throws -> APISubmission {
        let cells = [slotCell("test_\(id)", slot: "1"), testCell("assert well_formed()")]
        let path = app.submissionsDirectory + "\(id).ipynb"
        try Data(notebookJSON(cells: cells).utf8).write(to: URL(fileURLWithPath: path))
        let submission = APISubmission(
            id: id, testSetupID: f.setupID, zipPath: path, attemptNumber: 1, status: "complete",
            filename: "lab.ipynb", userID: try user.requireID(), kind: APISubmission.Kind.student)
        try await submission.save(on: app.db)
        return submission
    }

    private func runs(_ app: Application, group: UUID?) async throws -> [APIClassCoverageRun] {
        try await APIClassCoverageRun.query(on: app.db).filter(\.$groupID == group).all()
    }

    @Test func aLabsCorpusHoldsOnlyItsStudentsAndIsDebouncedOnItsOwn() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app)
            try await submit(app, f, user: f.ada, id: "lcorp_a")
            try await submit(app, f, user: f.alan, id: "lcorp_b")

            await scheduleClassCorpusRun(setupID: f.setupID, groupID: f.labA, app: app, on: app.db, logger: app.logger)
            await scheduleClassCorpusRun(setupID: f.setupID, groupID: f.labB, app: app, on: app.db, logger: app.logger)
            // Lab 101's run is in flight, so a second request adds nothing.
            await scheduleClassCorpusRun(setupID: f.setupID, groupID: f.labA, app: app, on: app.db, logger: app.logger)

            let labA = try await runs(app, group: f.labA)
            #expect(labA.map(\.contributors) == [[try f.ada.requireID()]])
            let labB = try await runs(app, group: f.labB)
            #expect(labB.map(\.contributors) == [[try f.alan.requireID()]], "two labs grade at once")
            #expect(try await runs(app, group: nil).isEmpty)
        }
    }

    @Test func aResultSchedulesTheRunOfItsLab() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app)
            try await submit(app, f, user: f.ada, id: "lcorp_a")
            let graces = try await submit(app, f, user: f.grace, id: "lcorp_g")

            await scheduleClassCorpusRun(
                afterSubmission: graces.id ?? "", userID: try f.grace.requireID(), setupID: f.setupID, app: app,
                on: app.db, logger: app.logger)
            #expect(try await APIClassCoverageRun.query(on: app.db).count() == 0, "no session, no run")

            await scheduleClassCorpusRun(
                afterSubmission: "lcorp_a", userID: try f.ada.requireID(), setupID: f.setupID, app: app,
                on: app.db, logger: app.logger)
            #expect(try await runs(app, group: f.labA).count == 1)
        }
    }

    @Test func aResultOnAWholeClassActivitySchedulesTheClassRun() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app, runsPerGroup: false)
            try await submit(app, f, user: f.ada, id: "lcorp_a")
            try await submit(app, f, user: f.grace, id: "lcorp_g")
            await scheduleClassCorpusRun(
                afterSubmission: "lcorp_g", userID: try f.grace.requireID(), setupID: f.setupID, app: app,
                on: app.db, logger: app.logger)
            let classRuns = try await runs(app, group: nil)
            #expect(classRuns.count == 1, "a session does not matter for the whole class")
            #expect(Set(classRuns.first?.contributors ?? []) == [try f.ada.requireID(), try f.grace.requireID()])
        }
    }

    @Test func eachLabsCoverageGoalReadsItsOwnRun() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app)
            try await submit(app, f, user: f.ada, id: "lcorp_a")
            try await submit(app, f, user: f.alan, id: "lcorp_b")
            await scheduleClassCorpusRun(setupID: f.setupID, groupID: f.labA, app: app, on: app.db, logger: app.logger)
            await scheduleClassCorpusRun(setupID: f.setupID, groupID: f.labB, app: app, on: app.db, logger: app.logger)

            for (group, earned) in [(f.labA, 9.0), (f.labB, 4.0)] {
                let run = try #require(try await runs(app, group: group).first)
                let job = try #require(try await APISubmission.find(run.submissionID, on: app.db))
                try await recordClassCoverageRun(
                    submission: job,
                    collection: TestOutcomeCollection(
                        submissionID: run.submissionID, testSetupID: f.setupID, attemptNumber: 1,
                        buildStatus: .passed, compilerOutput: nil, outcomes: [], totalTests: 10, passCount: 0,
                        failCount: 0, errorCount: 0, timeoutCount: 0, executionTimeMs: 1, totalPoints: 10,
                        earnedPoints: earned, runnerVersion: "test", timestamp: Date()),
                    on: app.db)
            }
            #expect(try await latestClassCoverageRun(testSetupID: f.setupID, on: app.db) == nil, "no class run")
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            func percent(_ group: UUID) async throws -> Double? {
                try await APIGroupAchievementResult.query(on: app.db)
                    .filter(\.$testSetupID == f.setupID).filter(\.$groupID == group).first()?.coveragePercent
            }
            #expect(try await percent(f.labA) == 90)
            #expect(try await percent(f.labB) == 40)
            #expect(try await APIAchievementResult.query(on: app.db).count() == 0, "no whole-class snapshot")
        }
    }

    @Test func deletingTheCourseRemovesTheLabRuns() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await loginAsAdmin("lcorp_admin", on: app)
            let f = try await fixture(app)
            try await submit(app, f, user: f.ada, id: "lcorp_a")
            await scheduleClassCorpusRun(setupID: f.setupID, groupID: f.labA, app: app, on: app.db, logger: app.logger)
            #expect(try await runs(app, group: f.labA).count == 1)

            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.isArchived = true
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let path = "/admin/courses/\(courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "\(path)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(try await APIClassCoverageRun.query(on: app.db).count() == 0, "a lab run names its contributors")
        }
    }
}
