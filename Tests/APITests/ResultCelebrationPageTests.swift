// Tests/APITests/ResultCelebrationPageTests.swift
//
// The result page renders the celebration the server chose
// (docs/result-celebration.md, J1): on the student's own latest graded
// submission only, from the attempts before it, and never for staff.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) struct ResultCelebrationPageTests {

    /// Inserts one graded attempt of the signed-in student.
    private func seedAttempt(
        app: Application, setupID: String, subID: String, attempt: Int, statuses: [TestStatus]
    ) async throws {
        let student = try await wrStudentUser(on: app)
        _ = try await wrInsertSubmission(
            id: subID, testSetupID: setupID, userID: student.requireID(), attemptNumber: attempt, on: app)
        _ = try await wrInsertResult(
            submissionID: subID,
            outcomes: statuses.enumerated().map { index, status in
                wrMakeOutcome(name: "test\(index).sh", tier: .pub, status: status)
            },
            on: app)
    }

    private func seedAssignment(app: Application, setupID: String) async throws {
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        try await wrInsertSetup(id: setupID, on: app)
        try await wrInsertAssignment(testSetupID: setupID, title: "Loops Lab", isOpen: true, on: app)
    }

    @Test func aFirstFullMarkPlaysTheFirstCelebration() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedAssignment(app: app, setupID: "setup_cel1")
            try await seedAttempt(
                app: app, setupID: "setup_cel1", subID: "sub_cel1", attempt: 1, statuses: [.pass, .pass])

            let html = try await getHTML("/submissions/sub_cel1", cookie: cookie, on: app)
            #expect(html.contains("data-celebrate=\"first\""))
            #expect(html.contains("data-grade-to=\"100\""))
            #expect(html.contains("data-announce=\"All 2 tests passed, 100%.\""))
            #expect(html.contains("score-figure score-figure-perfect"))
            #expect(html.contains("/celebrate-core.js"))
            #expect(html.contains("/celebrate.js"))
            #expect(html.contains("js-celebrate-live"))
        }
    }

    @Test func aHigherAttemptPlaysTheImprovedCelebrationWithItsGain() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedAssignment(app: app, setupID: "setup_cel2")
            try await seedAttempt(
                app: app, setupID: "setup_cel2", subID: "sub_cel2a", attempt: 1, statuses: [.pass, .fail, .fail, .fail])
            try await seedAttempt(
                app: app, setupID: "setup_cel2", subID: "sub_cel2b", attempt: 2, statuses: [.pass, .pass, .pass, .fail])

            let html = try await getHTML("/submissions/sub_cel2b", cookie: cookie, on: app)
            #expect(html.contains("data-celebrate=\"improved\""))
            #expect(html.contains("data-grade-from=\"25\""))
            #expect(html.contains("data-grade-to=\"75\""))
            #expect(html.contains("tier tier-open js-grade-gain\">+50%"))
            #expect(html.contains("3 of 4 tests passed, 75%, up from 25%."))
            #expect(!html.contains("score-figure-perfect"))
        }
    }

    @Test func aRepeatedFullMarkPlaysTheSparkleOnly() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedAssignment(app: app, setupID: "setup_cel3")
            try await seedAttempt(app: app, setupID: "setup_cel3", subID: "sub_cel3a", attempt: 1, statuses: [.pass])
            try await seedAttempt(app: app, setupID: "setup_cel3", subID: "sub_cel3b", attempt: 2, statuses: [.pass])

            let html = try await getHTML("/submissions/sub_cel3b", cookie: cookie, on: app)
            #expect(html.contains("data-celebrate=\"already\""))
            #expect(html.contains("score-figure score-figure-perfect"))
        }
    }

    @Test func aLowerOrEqualAttemptPlaysNothing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedAssignment(app: app, setupID: "setup_cel4")
            try await seedAttempt(
                app: app, setupID: "setup_cel4", subID: "sub_cel4a", attempt: 1, statuses: [.pass, .pass, .fail])
            try await seedAttempt(
                app: app, setupID: "setup_cel4", subID: "sub_cel4b", attempt: 2, statuses: [.pass, .fail, .fail])

            let html = try await getHTML("/submissions/sub_cel4b", cookie: cookie, on: app)
            #expect(html.contains("submission-bird"))
            #expect(!html.contains("data-celebrate"))
            #expect(!html.contains("/celebrate.js"))
        }
    }

    @Test func anEarlierAttemptThatIsNotTheLatestPlaysNothing() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            try await seedAssignment(app: app, setupID: "setup_cel5")
            try await seedAttempt(app: app, setupID: "setup_cel5", subID: "sub_cel5a", attempt: 1, statuses: [.pass])
            try await seedAttempt(app: app, setupID: "setup_cel5", subID: "sub_cel5b", attempt: 2, statuses: [.fail])

            let html = try await getHTML("/submissions/sub_cel5a", cookie: cookie, on: app)
            #expect(!html.contains("data-celebrate"))
            // The full-marks colour follows the grade, not the latest attempt.
            #expect(html.contains("score-figure score-figure-perfect"))
        }
    }

    @Test func staffReadingAStudentsResultSeeNoCelebration() async throws {
        try await withWebRoutesApp { app in
            _ = try await wrLoginAsStudent(on: app)
            try await seedAssignment(app: app, setupID: "setup_cel6")
            try await seedAttempt(app: app, setupID: "setup_cel6", subID: "sub_cel6", attempt: 1, statuses: [.pass])
            let staffCookie = try await wrLoginAsInstructor(on: app)
            let instructor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "instructor1").first())
            try await wrEnrollUser(instructor, on: app)

            let html = try await getHTML("/submissions/sub_cel6", cookie: staffCookie, on: app)
            #expect(!html.contains("data-celebrate"))
            #expect(!html.contains("/celebrate.js"))
        }
    }

    // MARK: - The history

    @Test func theHistoryReadsOnlyEarlierAttemptsAndKnowsTheLatest() {
        let attempts: [CelebrationHistory.Attempt] = [
            .init(number: 1, percent: 100), .init(number: 2, percent: 60), .init(number: 3, percent: 80),
        ]
        let middle = CelebrationHistory(current: 2, attempts: attempts)
        #expect(!middle.isLatest)
        #expect(middle.previousPercent == 100)
        #expect(middle.bestPercent == 100)

        let last = CelebrationHistory(current: 3, attempts: attempts)
        #expect(last.isLatest)
        #expect(last.previousPercent == 60)
        #expect(last.bestPercent == 100)

        let first = CelebrationHistory(current: 1, attempts: attempts)
        #expect(first.previousPercent == nil)
        #expect(first.bestPercent == nil)
    }
}
