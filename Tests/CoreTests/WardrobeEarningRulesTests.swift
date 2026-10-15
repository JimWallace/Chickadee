// Tests/CoreTests/WardrobeEarningRulesTests.swift
//
// The habit and persistence rules of the wardrobe (docs/student-wardrobe.md,
// E4) and the pace of the built-in rules across a term (E5).

import Testing

@testable import Core

@Suite struct WardrobeEarningRulesTests {

    private static let early = WardrobeProgress.earlyLeadSeconds
    private static let hour: Double = 60 * 60

    private static func graded(
        _ assignment: String, attempt: Int = 1, pass: Int = 1, of total: Int = 2, before seconds: Double? = nil
    ) -> WardrobeProgress.Graded {
        WardrobeProgress.Graded(
            assignmentID: assignment, attemptNumber: attempt, passCount: pass, totalTests: total,
            secondsBeforeDue: seconds)
    }

    // MARK: - The dreamy face: early on three assignments

    @Test func aSubmissionTwoDaysBeforeTheDueDateIsEarly() {
        #expect(Self.graded("a", before: Self.early).isEarly)
        #expect(!Self.graded("a", before: Self.early - 1).isEarly)
        #expect(!Self.graded("a", before: -Self.hour).isEarly, "a late submission")
        #expect(!Self.graded("a", before: nil).isEarly, "no due date")
    }

    @Test func earlyOnThreeAssignmentsEarnsTheDreamyFace() {
        let two = WardrobeProgress(graded: [
            Self.graded("a", before: Self.early), Self.graded("a", attempt: 2, before: Self.early),
            Self.graded("b", before: Self.early), Self.graded("c", before: Self.hour),
        ])
        #expect(two.earlyAssignments == 2)
        #expect(!WardrobeItem.earned(by: two).contains(.dreamyFace))
        let three = WardrobeProgress(graded: [
            Self.graded("a", before: Self.early), Self.graded("b", before: Self.early),
            Self.graded("c", before: Self.early * 2),
        ])
        #expect(WardrobeItem.earned(by: three).contains(.dreamyFace))
    }

    /// Early is a habit, not a grade: a failing early submission counts.
    @Test func anEarlySubmissionCountsWhateverItsResult() {
        let progress = WardrobeProgress(graded: [
            Self.graded("a", pass: 0, before: Self.early), Self.graded("b", pass: 0, before: Self.early),
            Self.graded("c", pass: 0, before: Self.early),
        ])
        #expect(WardrobeItem.earned(by: progress) == [.chirpFace, .dreamyFace])
    }

    // MARK: - The stitched ring: a comeback on three assignments

    @Test func fullMarksAfterAnAttemptThatFellShortIsAComeback() {
        let comeback = WardrobeProgress(graded: [
            Self.graded("a", attempt: 1, pass: 1), Self.graded("a", attempt: 2, pass: 2),
        ])
        #expect(comeback.comebackAssignments == 1)
        // Full marks first, then a lower attempt, is not a comeback.
        let slip = WardrobeProgress(graded: [
            Self.graded("a", attempt: 1, pass: 2), Self.graded("a", attempt: 2, pass: 1),
        ])
        #expect(slip.comebackAssignments == 0)
        // A comeback on another assignment does not count for this one.
        let elsewhere = WardrobeProgress(graded: [
            Self.graded("a", attempt: 1, pass: 1), Self.graded("b", attempt: 2, pass: 2),
        ])
        #expect(elsewhere.comebackAssignments == 0)
    }

    @Test func aComebackOnThreeAssignmentsEarnsTheStitchedRing() {
        let attempts = ["a", "b", "c"].flatMap { assignment in
            [Self.graded(assignment, attempt: 1, pass: 0), Self.graded(assignment, attempt: 3, pass: 2)]
        }
        let three = WardrobeProgress(graded: attempts)
        #expect(three.comebackAssignments == 3)
        #expect(WardrobeItem.earned(by: three).contains(.stitchedRing))
        let two = WardrobeProgress(graded: Array(attempts.prefix(4)))
        #expect(!WardrobeItem.earned(by: two).contains(.stitchedRing))
    }

    // MARK: - Pace across a term (E5)

    /// One student's term: for each week, the attempts on that week's
    /// assignment, as (passes out of 2, submitted early).
    private struct Student: Sendable {
        let name: String
        let weeks: [[(pass: Int, early: Bool)]]

        /// The items this student holds after `week` weeks.
        func items(after week: Int) -> Set<WardrobeItem> {
            var graded: [WardrobeProgress.Graded] = []
            for (index, attempts) in weeks.prefix(week).enumerated() {
                for (number, attempt) in attempts.enumerated() {
                    graded.append(
                        WardrobeProgress.Graded(
                            assignmentID: "week\(index + 1)", attemptNumber: number + 1, passCount: attempt.pass,
                            totalTests: 2,
                            secondsBeforeDue: attempt.early ? WardrobeProgress.earlyLeadSeconds : 60 * 60))
                }
            }
            return WardrobeItem.earned(by: WardrobeProgress(graded: graded))
        }
    }

    /// The five items a built-in rule earns, without an instructor's setup.
    private static let builtIn: Set<WardrobeItem> = [.chirpFace, .slyFace, .twoToneRing, .dreamyFace, .stitchedRing]

    /// Full marks first on odd weeks, a comeback on even weeks, always early.
    private static let strong = Student(
        name: "strong",
        weeks: (1...12).map { week in
            week.isMultiple(of: 2) ? [(1, true), (2, true)] : [(2, true)]
        })

    /// Short on every first attempt; a comeback every other week; early
    /// every fourth week.
    private static let steady = Student(
        name: "steady",
        weeks: (1...12).map { week in
            [(1, week.isMultiple(of: 4)), (week.isMultiple(of: 2) ? 2 : 1, false)]
        })

    /// Short on every attempt except three comebacks; never early.
    private static let struggling = Student(
        name: "struggling",
        weeks: (1...12).map { week in
            [5, 9, 12].contains(week) ? [(0, false), (2, false)] : [(0, false), (1, false)]
        })

    @Test func aStrongStudentHasTheBuiltInItemsByMidTerm() {
        #expect(Self.strong.items(after: 6) == Self.builtIn)
    }

    @Test func aSteadyStudentCollectsAtThePlannedPace() {
        #expect(Self.steady.items(after: 2).count == 1)
        #expect((2...3).contains(Self.steady.items(after: 6).count))
        #expect((4...5).contains(Self.steady.items(after: 12).count))
    }

    /// A student who struggles still collects more than the first item.
    @Test func aStrugglingStudentStillCollects() {
        #expect(Self.struggling.items(after: 2) == [.chirpFace])
        #expect(Self.struggling.items(after: 12).count >= 2)
    }
}
