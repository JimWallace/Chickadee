// Tests/APITests/Groups/LabGoalTests.swift
//
// Class goals of an activity that runs once per lab group (docs/lab-groups.md,
// slice 5a): a student counts in the lab of the session they joined last, else
// the group they are a member of; each lab's grade goal is counted over its own
// students, with no whole-class snapshot; each student earns their own lab's
// bonus on the result page, the LEARN push and the grades CSV, and a student in
// no lab earns none; a removed lab counts for nobody; every goal shape, a
// coverage goal too, is counted per lab; a lab's snapshot freezes at the deadline; and
// course delete removes the lab snapshots.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LabGoalTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-lab-goals")
    }

    private let setupID = "lgoal_setup"

    private struct Fixture {
        let setup: APITestSetup
        let assignment: APIAssignment
        let assignmentID: UUID
        let props: TestProperties
        let labA: UUID
        let labB: UUID
        let ada: UUID
        let ben: UUID
        let alan: UUID
        let grace: UUID
    }

    /// A per-group leaderboard with a 2-point goal that every student of a lab
    /// reaches 100%. ada (100%) and ben (50%) join Lab 101's session, alan
    /// (100%) joins Lab 102's, and grace, a member of Lab 102, joins nothing.
    private func fixture(dueAt: Date? = nil, extraGoals: [Achievement] = []) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: "LGL1", mode: .closed)
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "t.py")], language: .python,
            activity: ClassActivity(kind: .bestMetric, runsPerGroup: true),
            achievements: [
                Achievement(
                    id: "all_in", name: "Everyone passes", scope: .classWide,
                    conditions: [AchievementCondition(signal: .grade, comparator: .atLeast, value: 100)],
                    reward: AchievementReward(type: .points, label: "Lab goal", points: 2),
                    classFraction: 1)
            ] + extraGoals)
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, dueAt: dueAt)
        let assignmentID = try assignment.requireID()

        var students: [UUID] = []
        for name in ["lgoal_ada", "lgoal_ben", "lgoal_alan", "lgoal_grace"] {
            let id = try await makeTestStudent(on: app, username: name).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            students.append(id)
        }
        try await CourseGroupStore.setMembership(userID: students[3], groupID: labB, in: set, on: app.db)
        for (student, lab) in [(students[0], labA), (students[1], labA), (students[2], labB)] {
            try await join(assignmentID: assignmentID, group: lab, userID: student)
        }
        for (student, earned) in [(students[0], 4), (students[1], 2), (students[2], 4)] {
            try await grade(student, earned: earned)
        }
        return Fixture(
            setup: setup, assignment: assignment, assignmentID: assignmentID, props: props, labA: labA,
            labB: labB, ada: students[0], ben: students[1], alan: students[2], grace: students[3])
    }

    /// Opens the group's session, unless it is open, and joins `userID`.
    private func join(assignmentID: UUID, group: UUID, userID: UUID) async throws {
        try await joinSession(assignmentID: assignmentID, groupID: group, userID: userID, on: app.db)
    }

    private func grade(_ userID: UUID, earned: Int) async throws {
        let id = "lgoal_sub_\(UUID().uuidString.prefix(12))"
        _ = try await makeTestSubmission(on: app, id: id, setupID: setupID, userID: userID)
        try await APIResult(id: "lgoal_res_\(UUID().uuidString.prefix(12))", submissionID: id)
            .saveWithCollection(json: #"{"earnedPoints":\#(earned),"totalPoints":4}"#, on: app.db)
    }

    private func labRow(_ group: UUID) async throws -> APIGroupAchievementResult {
        try #require(
            try await APIGroupAchievementResult.query(on: app.db)
                .filter(\.$testSetupID == setupID).filter(\.$groupID == group).first())
    }

    @Test func aStudentCountsInTheLabTheyJoinedLastElseTheirGroup() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            // Staff move ben to Lab 102, and he joins its session.
            let set = try #require(try await CourseGroupStore.sets(courseID: f.setup.courseID, on: app.db).first)
            try await CourseGroupStore.setMembership(userID: f.ben, groupID: f.labB, in: set, on: app.db)
            try await join(assignmentID: f.assignmentID, group: f.labB, userID: f.ben)
            let labs = try await LabGoalGroups.byStudent(assignment: f.assignment, on: app.db)
            #expect(labs[f.ada] == f.labA)
            #expect(labs[f.ben] == f.labB, "the latest join wins")
            #expect(labs[f.grace] == f.labB, "a member who joined nothing counts in their group")
        }
    }

    @Test func eachLabsGoalCountsItsOwnStudents() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            let labA = try await labRow(f.labA)
            #expect(labA.studentsMeeting == 1)
            #expect(labA.denominator == 2)
            #expect(labA.progress == 0.5)
            let labB = try await labRow(f.labB)
            #expect(labB.studentsMeeting == 1)
            #expect(labB.denominator == 2, "grace counts in Lab 102 and has not passed")
            #expect(labB.progress == 0.5)
            #expect(try await APIAchievementResult.query(on: app.db).count() == 0, "no whole-class snapshot")
        }
    }

    @Test func aStudentEarnsTheirOwnLabsBonus() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            // Lab 102 now completes its goal: grace passes too.
            try await grade(f.grace, earned: 4)
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)

            func bonus(_ userID: UUID?) async throws -> Double {
                try await classGoalBonusPoints(testSetupID: setupID, props: f.props, userID: userID, on: app.db)
            }
            #expect(try await bonus(f.ada) == 1, "Lab 101 is half way: 2 × 0.5")
            #expect(try await bonus(f.alan) == 2, "Lab 102 is complete")
            #expect(try await bonus(nil) == 0)

            let table = try #require(
                try await ClassGoalBonusTable.load(assignment: f.assignment, props: f.props, on: app.db))
            #expect(table.points(for: f.ben) == 1)
            #expect(table.points(for: f.grace) == 2)
            #expect(table.points(for: UUID()) == 0, "a student in no lab earns no lab bonus")

            let views = try await loadClassGoalViews(
                testSetupID: setupID, props: f.props, userID: f.ada, on: app.db)
            #expect(views.map(\.progressPercent) == [50])

            // The LEARN and LTI push: both passed, so each earns the suite
            // total and their own lab's bonus on top.
            let ada = try #require(try await bestGradeForStudent(userID: f.ada, testSetupID: setupID, db: app.db))
            let alan = try #require(try await bestGradeForStudent(userID: f.alan, testSetupID: setupID, db: app.db))
            let total = try #require(ada.total)
            #expect(ada.points == total + 1)
            #expect(alan.points == total + 2)
        }
    }

    @Test func aStudentOfARemovedLabIsInNoLab() async throws {
        try await withApp(app) { _ in
            let f = try await fixture()
            let set = try #require(try await CourseGroupStore.sets(courseID: f.setup.courseID, on: app.db).first)
            let labA = try #require(try await APICourseGroup.find(f.labA, on: app.db))
            try await CourseGroupStore.removeGroup(labA, of: set, on: app.db)
            let labs = try await LabGoalGroups.byStudent(assignment: f.assignment, on: app.db)
            #expect(labs[f.ada] == nil, "a removed lab's join and membership do not count")
            #expect(labs[f.alan] == f.labB)
        }
    }

    @Test func everyGoalShapeIsCountedPerLab() async throws {
        try await withApp(app) { _ in
            let corpus = Achievement(
                id: "found", name: "Cover the reference", scope: .classWide,
                conditions: [AchievementCondition(signal: .classCoverage, comparator: .atLeast, value: 50)],
                reward: AchievementReward(type: .points, label: "Covered", points: 1),
                classFraction: 1)
            let f = try await fixture(extraGoals: [corpus])
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            #expect(try await APIAchievementResult.query(on: app.db).count() == 0, "no whole-class snapshot")
            let labRows = try await APIGroupAchievementResult.query(on: app.db)
                .filter(\.$groupID == f.labA).all().map(\.achievementID)
            #expect(Set(labRows) == ["all_in", "found"], "the coverage goal is counted per lab too")

            let snapshots = try await LabGoalGroups.snapshots(
                testSetupID: setupID, props: f.props, userID: f.ada, on: app.db)
            #expect(Set(snapshots.keys) == ["all_in", "found"])
        }
    }

    @Test func aLabsSnapshotFreezesAtTheDeadline() async throws {
        try await withApp(app) { _ in
            let f = try await fixture(dueAt: Date().addingTimeInterval(-10))
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            #expect(try await labRow(f.labA).locked)

            // A later pass changes nothing: ben passes after the freeze.
            try await grade(f.ben, earned: 4)
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            #expect(try await labRow(f.labA).progress == 0.5)
        }
    }

    @Test func deletingTheCourseRemovesTheLabSnapshots() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("lgoal_admin", on: app)
            let f = try await fixture()
            _ = try await evaluateClassGoalAchievements(on: app.db, logger: app.logger)
            #expect(try await APIGroupAchievementResult.query(on: app.db).count() == 2)

            let course = try #require(try await APICourse.find(f.setup.courseID, on: app.db))
            course.isArchived = true
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let path = "/admin/courses/\(f.setup.courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "\(path)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in #expect(res.status == .seeOther) })
            #expect(try await APIGroupAchievementResult.query(on: app.db).count() == 0)
        }
    }
}
