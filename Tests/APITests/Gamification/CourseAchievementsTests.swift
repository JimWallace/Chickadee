// Tests/APITests/Gamification/CourseAchievementsTests.swift
//
// Course achievements (docs/achievement-rewards.md, slice S3): a row saves at
// the level that can evaluate it and nowhere else, a target must name what
// the course has, and the evaluator stores what a student earns, once, from
// the student's own pages only.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct CourseAchievementsTests {

    private static func row(_ conditions: [ConditionRow], scope: String = "individual") -> AchievementRow {
        AchievementRow(id: "course_badge", name: "Two labs", scope: scope, conditions: conditions)
    }

    private static func graded(_ value: Double = 2, comparator: String = "atLeast") -> ConditionRow {
        ConditionRow(signal: "assignmentsGraded", comparator: comparator, value: value)
    }

    // MARK: - Levels

    @Test func anAssignmentRefusesACourseSignal() {
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.achievement(from: Self.row([Self.graded()]))
        }
    }

    @Test func aCourseRefusesAnAssignmentSignal() {
        let grade = ConditionRow(signal: "grade", comparator: "atLeast", value: 50)
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.achievement(from: Self.row([grade]), at: .course)
        }
    }

    @Test func aCourseAchievementIsAnIndividualBadge() throws {
        let achievement = try AchievementsEditing.achievement(from: Self.row([Self.graded()]), at: .course)
        #expect(achievement.scope == .individual)
        #expect(achievement.reward.type == .badge)
        #expect(achievement.conditions.first?.signal == .assignmentsGraded)
        for scope in ["classWide", "record"] {
            #expect(throws: WebAssignmentError.self) {
                try AchievementsEditing.achievement(from: Self.row([Self.graded()], scope: scope), at: .course)
            }
        }
    }

    @Test func aCourseConditionTakesAtLeastAWholeCountOfOneOrMore() {
        for bad in [
            Self.graded(comparator: "atMost"), Self.graded(comparator: "equals"), Self.graded(0), Self.graded(1.5),
        ] {
            #expect(throws: WebAssignmentError.self) {
                try AchievementsEditing.achievement(from: Self.row([bad]), at: .course)
            }
        }
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.achievement(from: Self.row([]), at: .course)
        }
    }

    @Test func assignmentsAtGradeNeedsAFloor() throws {
        let noFloor = ConditionRow(signal: "assignmentsAtGrade", comparator: "atLeast", value: 2)
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.achievement(from: Self.row([noFloor]), at: .course)
        }
        var withFloor = noFloor
        withFloor.gradeFloor = 80
        let achievement = try AchievementsEditing.achievement(from: Self.row([withFloor]), at: .course)
        #expect(achievement.conditions.first?.gradeFloor == 80)
    }

    @Test func aTargetKindMustNameASetOfAssignments() {
        let section = ConditionRow(
            signal: "assignmentsGraded", comparator: "atLeast", value: 1, targetKind: "section", targetRef: "x")
        let blank = ConditionRow(
            signal: "assignmentsGraded", comparator: "atLeast", value: 1, targetKind: "concept", targetRef: " ")
        for bad in [section, blank] {
            #expect(throws: WebAssignmentError.self) {
                try AchievementsEditing.achievement(from: Self.row([bad]), at: .course)
            }
        }
    }

    // MARK: - Targets against the course

    private static let sectionID = UUID().uuidString
    private static let context = CourseAchievementContext(
        sections: [(id: sectionID, name: "Unit 2")], assignmentPublicIDs: ["LAB001", "LAB002"])

    private static func targeted(_ kind: String, _ ref: String) throws -> Achievement {
        try AchievementsEditing.achievement(
            from: Self.row([
                ConditionRow(
                    signal: "assignmentsFullMarks", comparator: "atLeast", value: 1, targetKind: kind, targetRef: ref)
            ]), at: .course)
    }

    private static func storedTarget(_ kind: String, _ ref: String) throws -> AchievementTarget? {
        try AchievementsEditing.validate([try targeted(kind, ref)], againstCourse: context).first?.conditions.first?
            .target
    }

    @Test func aTargetIsStoredInItsNormalForm() throws {
        #expect(try Self.storedTarget("courseSection", "Unit 2")?.ref == Self.sectionID, "a name resolves to the id")
        #expect(try Self.storedTarget("courseSection", Self.sectionID.lowercased())?.ref == Self.sectionID)
        #expect(try Self.storedTarget("concept", "loops")?.ref == "loops")
        #expect(try Self.storedTarget("assignments", " LAB002 ,LAB001,")?.ref == "LAB002,LAB001")
    }

    @Test(arguments: [("courseSection", "Unit 9"), ("concept", "cooking"), ("assignments", "LAB001,LAB404")])
    func aTargetTheCourseDoesNotHaveIsRefused(kind: String, ref: String) throws {
        let achievement = try Self.targeted(kind, ref)
        #expect(throws: WebAssignmentError.self) {
            try AchievementsEditing.validate([achievement], againstCourse: Self.context)
        }
    }

    @Test func rowsRoundTripThroughTheCourseColumn() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try #require(
                try await APICourse.find(try await app.testCourseID(enrollmentMode: .auto), on: app.db))
            var row = Self.row([
                ConditionRow(
                    signal: "achievementsEarned", comparator: "atLeast", value: 2, targetKind: "concept",
                    targetRef: "loops", achievementRef: "first_try_perfect")
            ])
            row.detail = "Earn two badges on loop labs."
            let saved = try await AchievementsEditing.apply(rows: [row], course: course, on: app.db)

            let reloaded = try #require(try await APICourse.find(course.requireID(), on: app.db))
            #expect(reloaded.courseAchievements.count == 1)
            let rows = AchievementsEditing.rows(fromCourse: reloaded)
            #expect(rows.count == 1)
            #expect(rows.first?.id == saved.first?.id)
            #expect(rows.first?.detail == "Earn two badges on loop labs.")
            let condition = try #require(rows.first?.conditions?.first)
            #expect(condition.targetKind == "concept")
            #expect(condition.targetRef == "loops")
            #expect(condition.achievementRef == "first_try_perfect")
            #expect(condition.testRef == nil)

            try await AchievementsEditing.apply(rows: [], course: reloaded, on: app.db)
            #expect(try await APICourse.find(course.requireID(), on: app.db)?.achievementsJSON == nil)
        }
    }

    // MARK: - The evaluator

    private struct Seeded {
        let cookie: String
        let student: APIUser
        let course: APICourse
        let submissionIDs: [String]
    }

    /// A student with one graded submission on each of `labs` open labs, and
    /// a course achievement for two graded labs.
    private func seedCourse(labs: Int, hiddenLabs: Int = 0, on app: Application) async throws -> Seeded {
        let cookie = try await arLoginAsStudent(on: app)
        let student = try #require(try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
        try await arEnrollStudentInTestCourse(student, on: app)
        var submissionIDs: [String] = []
        for index in 0..<(labs + hiddenLabs) {
            let setupID = "course_ach_\(index)"
            try await arInsertSetup(id: setupID, on: app)
            try await arInsertAssignment(testSetupID: setupID, title: "Lab \(index)", isOpen: index < labs, on: app)
            let submissionID = "\(setupID)_sub"
            try await arInsertSubmission(
                id: submissionID, testSetupID: setupID, userID: try student.requireID(), on: app)
            try await wrInsertResult(
                submissionID: submissionID, outcomes: [wrMakeOutcome(name: "t1", status: .pass)], on: app)
            submissionIDs.append(submissionID)
        }
        let course = try #require(
            try await APICourse.find(try await app.testCourseID(enrollmentMode: .auto), on: app.db))
        try await AchievementsEditing.apply(rows: [Self.row([Self.graded()])], course: course, on: app.db)
        let saved = try #require(try await APICourse.find(course.requireID(), on: app.db))
        return Seeded(cookie: cookie, student: student, course: saved, submissionIDs: submissionIDs)
    }

    private func courseAwards(for student: APIUser, on app: Application) async throws -> [APIAchievementAward] {
        try await AchievementAwardStore.awards(for: student.requireID(), on: app.db).filter {
            $0.achievementLevel == .course
        }
    }

    @Test func aStudentWhoMeetsTheConditionsIsGrantedTheAchievementOnce() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedCourse(labs: 2, on: app)
            let userID = try seeded.student.requireID()

            let first = try await AchievementAwardStore.grantCourseAchievements(
                for: userID, in: seeded.course, on: app.db)
            let second = try await AchievementAwardStore.grantCourseAchievements(
                for: userID, in: seeded.course, on: app.db)

            #expect(first.count == 1)
            #expect(second.isEmpty)
            let award = try #require(try await courseAwards(for: seeded.student, on: app).first)
            #expect(award.ownerID == (try seeded.course.requireID().uuidString))
            #expect(award.achievementID == "course_badge")
            #expect(award.label == "Two labs")
            #expect(award.submissionID == nil)
        }
    }

    @Test func aHiddenAssignmentCountsForNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedCourse(labs: 1, hiddenLabs: 1, on: app)
            let granted = try await AchievementAwardStore.grantCourseAchievements(
                for: try seeded.student.requireID(), in: seeded.course, on: app.db)
            #expect(granted.isEmpty)
        }
    }

    @Test func theStudentsOwnResultPageGrantsIt() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedCourse(labs: 2, on: app)
            _ = try await getHTML("/submissions/\(seeded.submissionIDs[0])", cookie: seeded.cookie, on: app)
            #expect(try await courseAwards(for: seeded.student, on: app).map(\.achievementID) == ["course_badge"])
        }
    }

    @Test func theStudentsAccountPageGrantsIt() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedCourse(labs: 2, on: app)
            _ = try await getHTML("/account", cookie: seeded.cookie, on: app)
            #expect(try await courseAwards(for: seeded.student, on: app).count == 1)
        }
    }

    @Test func aStaffViewGrantsNothing() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedCourse(labs: 2, on: app)
            let instructorCookie = try await arLoginAsInstructor(on: app)
            _ = try await getHTML("/submissions/\(seeded.submissionIDs[0])", cookie: instructorCookie, on: app)
            #expect(try await courseAwards(for: seeded.student, on: app).isEmpty)
        }
    }

    @Test func achievementsEarnedCountsTheAssignmentBadgesInTheLedger() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedCourse(labs: 2, on: app)
            let userID = try seeded.student.requireID()
            let earnsOne = Self.row([ConditionRow(signal: "achievementsEarned", comparator: "atLeast", value: 1)])
            try await AchievementsEditing.apply(rows: [earnsOne], course: seeded.course, on: app.db)
            let course = try #require(try await APICourse.find(seeded.course.requireID(), on: app.db))
            #expect(
                try await AchievementAwardStore.grantCourseAchievements(for: userID, in: course, on: app.db).isEmpty)

            let badge = AchievementBadge(id: "first_try_perfect", label: "Ace", tooltip: "First try.")
            try await AchievementAwardStore.record(
                [.init(testSetupID: "course_ach_0", submissionID: seeded.submissionIDs[0], badges: [badge])],
                earnedBy: userID, on: app.db)
            #expect(
                try await AchievementAwardStore.grantCourseAchievements(for: userID, in: course, on: app.db).count == 1)
        }
    }

    @Test func deletingTheCourseAwardsLeavesOtherCourses() async throws {
        try await withAssignmentRoutesApp { app in
            let seeded = try await seedCourse(labs: 2, on: app)
            let userID = try seeded.student.requireID()
            try await AchievementAwardStore.grantCourseAchievements(for: userID, in: seeded.course, on: app.db)
            let other = APIAchievementAward(
                userID: userID, level: .course, ownerID: UUID().uuidString, achievementID: "x",
                submissionID: nil, label: "Other", detail: nil)
            try await other.create(on: app.db)

            try await AchievementAwardStore.deleteCourseAwards(forCourse: try seeded.course.requireID(), on: app.db)

            #expect(try await courseAwards(for: seeded.student, on: app).map(\.label) == ["Other"])
        }
    }
}
