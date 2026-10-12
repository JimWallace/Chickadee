// Tests/APITests/ElementaryPageFixtures+History.swift
//
// The submission history, diff and result pages (the "History" group of the
// Leaf-to-Elementary migration), rendered for ElementaryPageGuardTests.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var historyPages: [ElementaryPageFixture] {
        [
            submissionDiffPage, submissionHistoryPage, studentAssignmentHistoryPage, adminImportResultPage,
            adminEnrollCSVResultPage,
        ]
    }

    private static var historyRows: [AssignmentSubmissionHistoryRow] {
        [
            AssignmentSubmissionHistoryRow(
                submissionID: "sub_a", attemptNumber: 2, status: "complete", submittedAt: "Oct 1, 2026 10:00",
                gradeText: "80%"),
            AssignmentSubmissionHistoryRow(
                submissionID: "sub_b", attemptNumber: 1, status: "pending", submittedAt: "—", gradeText: "—"),
        ]
    }

    static var submissionDiffPage: ElementaryPageFixture {
        let rows = [
            LineDiffRow(kind: .context, oldNumber: 1, newNumber: 1, text: notebookDiffCellMarker),
            LineDiffRow(kind: .removed, oldNumber: 2, newNumber: nil, text: "x = 1"),
            LineDiffRow(kind: .added, oldNumber: nil, newNumber: 2, text: "x = 2"),
            LineDiffRow(kind: .fold, oldNumber: 3, newNumber: 3, text: "4 unchanged lines"),
            LineDiffRow(kind: .added, oldNumber: nil, newNumber: 7, text: notebookDiffCellMarker),
        ]
        func render(username: String?, unavailable: String?, rows: [LineDiffRow]) -> String {
            SubmissionDiffPage(
                page: page(currentUser: signedInAdmin), assignmentTitle: "Lab 1", studentName: "Ada",
                studentUsername: username, attemptNumber: 3, comparedLabel: "starter notebook → lab1.ipynb",
                unavailableReason: unavailable, rows: rows, resultsURL: "/submissions/sub_a",
                historyURL: "/instructor/abc123/submissions"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "SubmissionDiffPage",
            archetype: .titlebarPage,
            renders: [
                render(username: "ada", unavailable: nil, rows: rows),
                render(username: nil, unavailable: nil, rows: []),
                render(username: nil, unavailable: "The submitted file is no longer on disk.", rows: []),
            ]
        )
    }

    static var submissionHistoryPage: ElementaryPageFixture {
        let rows = historyRows.map { history in
            SubmissionHistoryRow(
                history: history, submissionFilename: nil, canOpenInNotebook: history.submissionID == "sub_a",
                openInNotebookURL: history.submissionID == "sub_a"
                    ? "/testsetups/ts1/notebook?submissionID=sub_a" : nil)
        }
        return ElementaryPageFixture(
            typeName: "SubmissionHistoryPage",
            archetype: .plainStudentPage,
            renders: [
                SubmissionHistoryPage(page: page(currentUser: signedInAdmin), assignmentTitle: "Lab 1", rows: rows)
                    .render(),
                SubmissionHistoryPage(page: page(), assignmentTitle: "Lab 1", rows: []).render(),
            ]
        )
    }

    static var studentAssignmentHistoryPage: ElementaryPageFixture {
        func render(username: String?, showsDiff: Bool, rows: [AssignmentSubmissionHistoryRow]) -> String {
            StudentAssignmentHistoryPage(
                page: page(currentUser: signedInAdmin), studentName: "Ada", studentUsername: username,
                assignmentID: "abc123", assignmentTitle: "Lab 1", backURL: "/instructor/abc123/submissions",
                backLabel: "Back to submissions", showsDiff: showsDiff,
                historyPath: "/instructor/abc123/students/u1/history", rows: rows
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "StudentAssignmentHistoryPage",
            archetype: .titlebarPage,
            renders: [
                render(username: "ada", showsDiff: true, rows: historyRows),
                render(username: nil, showsDiff: false, rows: historyRows),
                render(username: nil, showsDiff: true, rows: []),
            ]
        )
    }

    static var adminImportResultPage: ElementaryPageFixture {
        func render(termLabel: String?, usersCreated: Int) -> String {
            var tally = ImportTally(
                courseID: UUID(), courseCode: "CS135", courseName: "Design", termLabel: termLabel)
            tally.usersCreated = usersCreated
            tally.testSetupsImported = 4
            return AdminImportResultPage(page: page(currentUser: signedInAdmin), tally: tally).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminImportResultPage",
            archetype: .titlebarPage,
            renders: [
                render(termLabel: "Fall 2026", usersCreated: 2),
                render(termLabel: nil, usersCreated: 0),
            ]
        )
    }

    static var adminEnrollCSVResultPage: ElementaryPageFixture {
        func render(preEnrolled: Int, rejected: [String]) -> String {
            AdminEnrollCSVResultPage(
                page: page(currentUser: signedInAdmin), courseCode: "CS135", courseName: "Design",
                result: EnrollUsernamesResult(
                    enrolledCount: 3, preEnrolledCount: preEnrolled, alreadyEnrolledCount: 1,
                    rejectedUsernames: rejected),
                returnURL: "/instructor"
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminEnrollCSVResultPage",
            archetype: .titlebarPage,
            renders: [
                render(preEnrolled: 2, rejected: ["bad;name"]),
                render(preEnrolled: 0, rejected: []),
            ]
        )
    }
}
