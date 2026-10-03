// Tests/APITests/LatestSubmissionCellTests.swift
//
// `LatestSubmissionCell` holds the rules three row builders used to spell
// each on their own (#1711): the count of other submissions, the empty ID and
// em-dash with no submission, and an override before the best grade.

import Testing

@testable import APIServer

@Suite struct LatestSubmissionCellTests {

    @Test func noSubmissionIsAnEmptyCell() {
        let cell = LatestSubmissionCell(
            count: 0, latestSubmissionID: nil, latestSubmittedAtText: nil, bestPercent: nil, overridePercent: nil)
        #expect(cell.submissionCount == 0)
        #expect(!cell.hasLatestSubmission)
        #expect(cell.latestSubmissionID.isEmpty)
        #expect(cell.latestSubmittedAtText == "—")
        #expect(cell.additionalSubmissionCount == 0)
        #expect(cell.bestGradeText == nil)
        #expect(!cell.gradeIsOverridden)
    }

    @Test func theLatestOfThreeLeavesTwoMore() {
        let cell = LatestSubmissionCell(
            count: 3, latestSubmissionID: "sub_3", latestSubmittedAtText: "Oct 2, 2026 4:00 PM",
            bestPercent: 80, overridePercent: nil)
        #expect(cell.hasLatestSubmission)
        #expect(cell.latestSubmissionID == "sub_3")
        #expect(cell.latestSubmittedAtText == "Oct 2, 2026 4:00 PM")
        #expect(cell.additionalSubmissionCount == 2)
        #expect(cell.bestGradeText == "80%")
        #expect(!cell.gradeIsOverridden)
    }

    /// A submission with no time on it still links, under an em-dash.
    @Test func aSubmissionWithNoTimeShowsAnEmDash() {
        let cell = LatestSubmissionCell(
            count: 1, latestSubmissionID: "sub_1", latestSubmittedAtText: nil, bestPercent: nil, overridePercent: nil)
        #expect(cell.hasLatestSubmission)
        #expect(cell.latestSubmittedAtText == "—")
    }

    /// An override is the grade that counts, even below the best grade and
    /// even when there is no best grade.
    @Test(arguments: [(best: Int?.some(90), override: 70), (best: nil, override: 0)])
    func anOverrideWinsOverTheBestGrade(best: Int?, override: Int) {
        let cell = LatestSubmissionCell(
            count: 1, latestSubmissionID: "sub_1", latestSubmittedAtText: "t", bestPercent: best,
            overridePercent: override)
        #expect(cell.bestGradeText == "\(override)%")
        #expect(cell.gradeIsOverridden)
    }
}
