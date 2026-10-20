// Tests/CoreTests/CourseProgressTests.swift
//
// The course signals (docs/achievement-rewards.md, decision 3, slice S3):
// each one counted over a synthetic course, each target, and the rule that a
// signal at the wrong level is unmet.

import Foundation
import Testing

@testable import Core

@Suite struct CourseProgressTests {

    private static let early = WardrobeProgress.earlyLeadSeconds

    /// Four labs students can see: two in the "unit2" section, two tagged
    /// with a concept.
    private static let assignments = [
        CourseProgress.Assignment(testSetupID: "s1", publicID: "LAB001", courseSectionID: "unit1", concept: .loops),
        CourseProgress.Assignment(testSetupID: "s2", publicID: "LAB002", courseSectionID: "unit2", concept: .functions),
        CourseProgress.Assignment(testSetupID: "s3", publicID: "LAB003", courseSectionID: "unit2"),
        CourseProgress.Assignment(testSetupID: "s4", publicID: "LAB004"),
    ]

    private static func graded(
        _ setup: String, attempt: Int = 1, pass: Int, of total: Int = 2, grade: Int? = nil,
        before seconds: Double? = nil, concept: AssignmentConcept? = nil
    ) -> WardrobeProgress.Graded {
        WardrobeProgress.Graded(
            assignmentID: setup, attemptNumber: attempt, passCount: pass, totalTests: total,
            secondsBeforeDue: seconds, concept: concept, gradePercent: grade ?? (total > 0 ? pass * 100 / total : nil))
    }

    /// s1: full marks on the first try, early. s2: a comeback to full marks.
    /// s3: half marks. s4: nothing. "hidden": full marks on an assignment
    /// students cannot see.
    private static let progress = CourseProgress(
        assignments: assignments,
        graded: [
            graded("s1", pass: 2, before: early, concept: .loops),
            graded("s2", pass: 0, concept: .functions),
            graded("s2", attempt: 2, pass: 2, concept: .functions),
            graded("s3", pass: 1),
            graded("hidden", pass: 2, before: early, concept: .binary),
        ],
        awards: [
            CourseProgress.Award(testSetupID: "s1", achievementID: "first_try_perfect"),
            CourseProgress.Award(testSetupID: "s2", achievementID: "comeback"),
            CourseProgress.Award(testSetupID: "hidden", achievementID: "first_try_perfect"),
        ])

    private static func count(
        _ signal: AchievementSignal, over target: AchievementTarget? = nil, floor: Double? = nil, ref: String? = nil
    ) -> Int? {
        progress.count(
            for: AchievementCondition(
                signal: signal, comparator: .atLeast, value: 1, target: target, gradeFloor: floor,
                achievementRef: ref))
    }

    // MARK: - Each signal over the whole course

    @Test func eachSignalCountsTheVisibleAssignmentsOnly() {
        #expect(Self.count(.assignmentsGraded) == 3)
        #expect(Self.count(.assignmentsFullMarks) == 2)
        #expect(Self.count(.assignmentsEarly) == 1)
        #expect(Self.count(.assignmentsComeback) == 1)
        #expect(Self.count(.conceptsAtFullMarks) == 2)
        #expect(Self.count(.achievementsEarned) == 2)
    }

    @Test func assignmentsAtGradeReadsTheBestGradeAgainstTheFloor() {
        #expect(Self.count(.assignmentsAtGrade, floor: 50) == 3)
        #expect(Self.count(.assignmentsAtGrade, floor: 51) == 2)
        #expect(Self.count(.assignmentsAtGrade, floor: 100) == 2)
        #expect(Self.count(.assignmentsAtGrade) == nil, "no floor cannot be counted")
    }

    @Test func achievementsEarnedCountsOneAchievementWhenARefNamesIt() {
        #expect(Self.count(.achievementsEarned, ref: "first_try_perfect") == 1)
        #expect(Self.count(.achievementsEarned, ref: "comeback") == 1)
        #expect(Self.count(.achievementsEarned, ref: "nothing") == 0)
    }

    // MARK: - Targets

    @Test func aCourseSectionTargetCountsThatSectionOnly() {
        let unit2 = AchievementTarget(kind: .courseSection, ref: "unit2")
        #expect(Self.count(.assignmentsGraded, over: unit2) == 2)
        #expect(Self.count(.assignmentsFullMarks, over: unit2) == 1)
        #expect(Self.count(.assignmentsGraded, over: AchievementTarget(kind: .courseSection, ref: "none")) == 0)
    }

    @Test func aConceptTargetCountsTheTaggedAssignmentsOnly() {
        let loops = AchievementTarget(kind: .concept, ref: AssignmentConcept.loops.rawValue)
        #expect(Self.count(.assignmentsFullMarks, over: loops) == 1)
        #expect(Self.count(.assignmentsComeback, over: loops) == 0)
        #expect(Self.count(.assignmentsGraded, over: AchievementTarget(kind: .concept, ref: "unknown")) == nil)
    }

    @Test func anAssignmentsTargetCountsTheListedPublicIDs() {
        let listed = AchievementTarget(kind: .assignments, ref: "LAB002, LAB003,,LAB999")
        #expect(Self.count(.assignmentsGraded, over: listed) == 2)
        #expect(Self.count(.assignmentsFullMarks, over: listed) == 1)
        #expect(Self.count(.achievementsEarned, over: listed) == 1)
        #expect(CourseProgress.publicIDs(in: " LAB002, ,LAB003 ") == ["LAB002", "LAB003"])
    }

    @Test(arguments: [TargetKind.assignmentGrade, .suiteItem, .section, .testPass])
    func aTargetThatNamesNoAssignmentsCountsNothing(kind: TargetKind) {
        #expect(!kind.namesCourseAssignments)
        #expect(Self.count(.assignmentsGraded, over: AchievementTarget(kind: kind, ref: "x")) == nil)
    }

    // MARK: - Levels

    @Test(arguments: AchievementSignal.allCases)
    func aSignalLivesAtTheAssignmentLevelOrTheCourseLevelNeverBoth(signal: AchievementSignal) {
        if signal.readsTheCourse {
            #expect(signal.allowedLevels == [.course, .site])
            #expect(!signal.readsTheWholeClass)
            #expect(!signal.readsTheStandings)
            #expect(
                !AchievementCondition(signal: signal, comparator: .atLeast, value: 0)
                    .isSatisfied(by: AchievementSignals(gradePercent: 100)))
        } else {
            #expect(signal.allowedLevels == [.assignment])
            #expect(
                Self.progress.count(for: AchievementCondition(signal: signal, comparator: .atLeast, value: 0)) == nil)
            #expect(
                !AchievementCondition(signal: signal, comparator: .atLeast, value: 0).isSatisfied(by: Self.progress))
        }
    }

    // MARK: - Evaluating an achievement

    private static func badge(_ match: ConditionMatch, _ conditions: [AchievementCondition]) -> Achievement {
        Achievement(
            id: "course", name: "Course", scope: .individual, conditions: conditions, match: match,
            reward: AchievementReward(type: .badge, label: "Course"))
    }

    @Test func aCourseAchievementHonoursItsComparatorsAndItsMatch() {
        let three = AchievementCondition(signal: .assignmentsGraded, comparator: .atLeast, value: 3)
        let four = AchievementCondition(signal: .assignmentsGraded, comparator: .atLeast, value: 4)
        #expect(Self.badge(.all, [three]).isSatisfied(by: Self.progress))
        #expect(!Self.badge(.all, [four]).isSatisfied(by: Self.progress))
        #expect(!Self.badge(.all, [three, four]).isSatisfied(by: Self.progress))
        #expect(Self.badge(.any, [three, four]).isSatisfied(by: Self.progress))
    }

    @Test func aCourseAchievementWithNoConditionsIsEarnedByNobody() {
        #expect(!Self.badge(.all, []).isSatisfied(by: Self.progress))
        #expect(!Self.badge(.any, []).isSatisfied(by: Self.progress))
    }

    @Test func aCourseWithNoWorkCountsZero() {
        let empty = CourseProgress(assignments: Self.assignments, graded: [])
        #expect(empty.count(for: AchievementCondition(signal: .assignmentsGraded, comparator: .atLeast, value: 1)) == 0)
    }

    // MARK: - The manifest shape

    @Test func theNewConditionFieldsRoundTripAndOldConditionsDecode() throws {
        let condition = AchievementCondition(
            signal: .assignmentsAtGrade, comparator: .atLeast, value: 2,
            target: AchievementTarget(kind: .courseSection, ref: "unit2"), gradeFloor: 80, achievementRef: nil)
        let data = try JSONEncoder().encode(condition)
        #expect(try JSONDecoder().decode(AchievementCondition.self, from: data) == condition)

        let old = #"{"signal":"grade","comparator":"atLeast","value":80}"#
        let decoded = try JSONDecoder().decode(AchievementCondition.self, from: Data(old.utf8))
        #expect(decoded.gradeFloor == nil)
        #expect(decoded.achievementRef == nil)
    }
}
