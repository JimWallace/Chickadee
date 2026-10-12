// Tests/APITests/ElementaryPageFixtures+Submissions.swift
//
// The assignment roster, one student's course submissions and the CSV
// enrolment form (the "Submissions" group of the Leaf-to-Elementary
// migration), rendered for ElementaryPageGuardTests.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    /// All three are the nearest archetype, `.titlebarPage`, and none shows a
    /// `.page-subtitle`. `AssignmentSubmissionsPage` has a `.page-section` only
    /// for its coverage and tournament blocks; `CourseStudentSubmissionsPage`
    /// has none.
    static var submissionsPages: [ElementaryPageFixture] {
        [assignmentSubmissionsPage, courseStudentSubmissionsPage, instructorEnrollCSVPage]
    }

    // MARK: - Shared values

    private static func latestCell(count: Int, latest: String?, best: Int?, override: Int?) -> LatestSubmissionCell {
        LatestSubmissionCell(
            count: count, latestSubmissionID: latest,
            latestSubmittedAtText: latest == nil ? nil : "Oct 1, 2026 10:00", bestPercent: best,
            overridePercent: override)
    }

    private static func sparkBars(_ heights: [Int]) -> [SparklineBar] {
        heights.enumerated().map { index, height in
            SparklineBar(heightPercent: height, isEmpty: height == 0, title: "Bucket \(index)")
        }
    }

    private static var statCards: [AssignmentStatCard] {
        [
            AssignmentStatCard(
                label: "Students Submitted", value: "3/5", hasSpark: false, sparkSummary: "", bars: [],
                cyclable: false, windowChip: "", windows: []),
            AssignmentStatCard(
                label: "Avg Attempts/Student", value: "1.5", hasSpark: true,
                sparkSummary: "Submission attempts per student.", bars: sparkBars([100, 0, 20]), cyclable: false,
                windowChip: "", windows: []),
            AssignmentStatCard(
                label: "Submissions", value: "4", hasSpark: false, sparkSummary: "", bars: [], cyclable: true,
                windowChip: "24h",
                windows: [
                    SubmissionsTrendWindow(
                        key: "24h", headline: "4", initiallyHidden: false, bars: sparkBars([0, 100])),
                    SubmissionsTrendWindow(
                        key: "7d", headline: "9", initiallyHidden: true, bars: sparkBars([50, 100, 0])),
                ]),
        ]
    }

    private static var rosterStudentRows: [AssignmentStudentRow] {
        func row(_ id: String, cell: LatestSubmissionCell, spent: Bool, passing: String?) -> AssignmentStudentRow {
            AssignmentStudentRow(
                studentID: id, studentUUID: "uuid-\(id)", surname: "Lovelace", givenNames: "Ada",
                gradeText: cell.bestGradeText ?? "—", gradeOverridePercent: 50, latest: cell,
                latestSubmittedAtEpoch: 1_700_000_000, fullHistoryURL: "/instructor/abc123/students/uuid-\(id)/history",
                bestGradePercent: nil, secretRevealSpent: spent, passingLabel: passing,
                isPassing: passing == "passing")
        }
        return [
            row(
                "s1", cell: latestCell(count: 3, latest: "sub1", best: 80, override: nil), spent: true,
                passing: "passing"),
            row(
                "s2", cell: latestCell(count: 1, latest: "sub2", best: 40, override: 55), spent: false,
                passing: "below threshold"),
            row("s3", cell: latestCell(count: 0, latest: nil, best: nil, override: nil), spent: false, passing: nil),
        ]
    }

    // MARK: - Pages

    static var assignmentSubmissionsPage: ElementaryPageFixture {
        let coverage = [
            AssignmentCoverageRow(
                item: "test_edge", found: true, foundBy: "ada", foundAt: "Oct 1, 2026 10:00",
                foundAtISO: "2026-10-01T14:00:00Z"),
            AssignmentCoverageRow(item: "test_empty", found: false, foundBy: "", foundAt: "", foundAtISO: ""),
        ]
        let tournament = TournamentControlFacts(
            isTournamentKind: true, statusText: "Bracket: round 2 of 3 in progress.", hasRunInProgress: true,
            scheduleOptions: TournamentScheduleOption.options(), leaderboardURL: "/testsetups/ts1/leaderboard")
        func render(
            rows: [AssignmentStudentRow], secret: Bool, aiFeedback: Bool, coverage: [AssignmentCoverageRow],
            tournament: TournamentControlFacts, flash: FlashMessages = FlashMessages()
        ) -> String {
            AssignmentSubmissionsPage(
                page: page(currentUser: signedInAdmin), flash: flash, assignmentID: "abc123",
                assignmentTitle: "Lab 1", metrics: rows.isEmpty ? [] : statCards, rows: rows,
                secretRevealEnabled: secret, aiFeedbackOpen: aiFeedback, coverageRows: coverage,
                coverageSummary: "1 / 2 items found", tournament: tournament
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AssignmentSubmissionsPage",
            archetype: .titlebarPage,
            renders: [
                render(
                    rows: rosterStudentRows, secret: true, aiFeedback: true, coverage: coverage, tournament: tournament),
                render(
                    rows: rosterStudentRows, secret: false, aiFeedback: false, coverage: [], tournament: .none,
                    flash: FlashMessages(success: "Grade override saved.")),
                render(
                    rows: [], secret: false, aiFeedback: false, coverage: [], tournament: .none,
                    flash: FlashMessages(error: "Submission not found.")),
            ]
        )
    }

    static var courseStudentSubmissionsPage: ElementaryPageFixture {
        func row(
            _ id: String, status: String, due: String?, effective: String?, cell: LatestSubmissionCell,
            badges: [AchievementBadge]
        ) -> StudentAssignmentRow {
            StudentAssignmentRow(
                assignmentID: id, title: "Lab \(id)", status: status, isOpen: status == "open", dueAtText: due,
                effectiveDueAtText: effective, hasExtension: effective != nil, extensionFormInput: "2026-10-01T10:00",
                extensionSavePath: "/CS135-F26/students/tok/assignments/\(id)/extension",
                extensionDeletePath: "/CS135-F26/students/tok/assignments/\(id)/extension/delete",
                retestPath: "/CS135-F26/students/tok/assignments/\(id)/retest",
                resetPath: "/CS135-F26/students/tok/assignments/\(id)/reset-notebook",
                historyURL: "/CS135-F26/students/tok/assignments/\(id)/history", latest: cell,
                gradeOverridePercent: cell.gradeIsOverridden ? 90 : 0,
                gradeOverrideSavePath: "/CS135-F26/students/tok/assignments/\(id)/grade-override",
                gradeOverrideClearPath: "/CS135-F26/students/tok/assignments/\(id)/grade-override/delete",
                badges: badges)
        }
        let badge = AchievementBadge(id: "first-try", label: "First try", tooltip: "Passed on the first attempt")
        let rows = [
            row(
                "1", status: "open", due: "Oct 1, 2026 23:59", effective: "Oct 3, 2026 23:59",
                cell: latestCell(count: 3, latest: "sub1", best: 80, override: 90), badges: [badge]),
            row(
                "2", status: "closed", due: nil, effective: "Oct 3, 2026 23:59",
                cell: latestCell(count: 1, latest: "sub2", best: 70, override: nil), badges: []),
            row(
                "3", status: "closed", due: "Oct 5, 2026 23:59", effective: nil,
                cell: latestCell(count: 0, latest: nil, best: nil, override: nil), badges: []),
        ]
        let sections = [
            StudentAssignmentSectionContext(sectionID: "sec1", name: "Labs", rows: Array(rows[0..<2])),
            StudentAssignmentSectionContext(sectionID: "sec2", name: "Exams", rows: []),
        ]
        func render(
            sections: [StudentAssignmentSectionContext], ungrouped: [StudentAssignmentRow], hasSections: Bool
        ) -> String {
            CourseStudentSubmissionsPage(
                page: page(currentUser: signedInAdmin), studentName: "Ada Lovelace", studentUsername: "alovelace",
                courseName: "CS135 — Design", backURL: "/instructor", sections: sections, ungroupedRows: ungrouped,
                hasSections: hasSections
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "CourseStudentSubmissionsPage",
            archetype: .titlebarPage,
            renders: [
                render(sections: sections, ungrouped: [rows[2]], hasSections: true),
                render(sections: [], ungrouped: rows, hasSections: false),
                render(sections: [], ungrouped: [], hasSections: false),
            ]
        )
    }

    static var instructorEnrollCSVPage: ElementaryPageFixture {
        func render(error: String?) -> String {
            InstructorEnrollCSVPage(
                page: page(currentUser: signedInAdmin), courseID: "c1", courseCode: "CS135", courseName: "Design",
                error: error
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "InstructorEnrollCSVPage",
            archetype: .titlebarPage,
            renders: [
                render(error: nil),
                render(error: "Upload a CSV file or type at least one user ID to enrol."),
            ]
        )
    }
}
