// Tests/APITests/SubmissionFailedCountTests.swift
//
// The "Failed" tile on a results page is the one count that is not neutral
// information (#2399): it takes the alert modifier only when a test failed,
// so a clean submission does not show a red 0.

import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite struct SubmissionFailedCountTests {

    private func renderResults(
        app: Application, setupID: String, subID: String, status: TestStatus
    ) async throws -> String {
        let cookie = try await wrLoginAsStudent(on: app)
        let student = try await wrStudentUser(on: app)
        try await wrEnrollUser(student, on: app)
        try await wrInsertSetup(id: setupID, on: app)
        try await wrInsertAssignment(testSetupID: setupID, title: "Count Lab", isOpen: true, on: app)
        try await wrInsertSubmission(
            id: subID, testSetupID: setupID, userID: student.requireID(), on: app)
        try await wrInsertResult(
            submissionID: subID,
            outcomes: [wrMakeOutcome(name: "test.sh", tier: .pub, status: status)],
            on: app)
        return try await getHTML("/submissions/\(subID)", cookie: cookie, on: app)
    }

    @Test func failedCountIsAlertWhenATestFailed() async throws {
        try await withWebRoutesApp { app in
            let html = try await renderResults(
                app: app, setupID: "setup_fc1", subID: "sub_fc1", status: .fail)
            #expect(html.contains("diagnostic-value diagnostic-value-alert"))
        }
    }

    @Test func failedCountIsNeutralWhenNothingFailed() async throws {
        try await withWebRoutesApp { app in
            let html = try await renderResults(
                app: app, setupID: "setup_fc2", subID: "sub_fc2", status: .pass)
            #expect(html.contains("diagnostics-cards"))
            #expect(!html.contains("diagnostic-value-alert"))
        }
    }
}
