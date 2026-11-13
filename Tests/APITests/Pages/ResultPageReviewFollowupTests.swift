// Tests/APITests/Pages/ResultPageReviewFollowupTests.swift
//
// Follow-ups from the review of the UI audit #3007 fixes:
// - the final pending-band state carries a plain link to the results, so a
//   reader is not stuck when the automatic reload does not happen;
// - the result page and the state poller share one definition of "waiting"
//   (`SubmissionStatus.awaitsResult`), so a page first loaded in `.running`
//   polls too;
// - `DueDate` prints the absolute date once and seeds the relative span empty.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct SubmissionStateRegionFallbackTests {

    @Test func theFinalStateLinksToTheResults() {
        let html = SubmissionStateRegion(status: .complete, resultsURL: "/submissions/s1").render()
        #expect(html.contains("data-submission-final"))
        #expect(html.contains("href=\"/submissions/s1\""))
        #expect(html.contains("View results"))
    }

    @Test func aWaitingStateHasNoLink() {
        let html = SubmissionStateRegion(status: .running, resultsURL: "/submissions/s1").render()
        #expect(html.contains("Grading"))
        #expect(!html.contains("href="))
    }
}

@Suite struct DueDateRenderingTests {

    @Test func theAbsoluteDateShowsOnceAndTheRelativeSpanIsEmpty() {
        let html = DueDate(iso: "2026-11-20T23:59:00Z", text: "Fri Nov 20, 23:59").render()
        #expect(html.components(separatedBy: "Fri Nov 20, 23:59").count == 2, "the date appears exactly once")
        #expect(html.contains("data-iso=\"2026-11-20T23:59:00Z\"></span>"), "the relative span is seeded empty")
        #expect(!html.contains("·"), "the separator comes from CSS, not the markup")
    }

    @Test func noISOMeansNoRelativeSpan() {
        let html = DueDate(iso: "", text: "Fri Nov 20, 23:59").render()
        #expect(!html.contains("js-relative-time"))
        #expect(html.contains("Due Fri Nov 20, 23:59"))
    }
}

@Suite(.serialized, .timeLimit(.minutes(5))) struct RunningSubmissionPollTests {

    @Test func aPageFirstLoadedWhileRunningPolls() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrInsertSetup(id: "setup_followup_run", on: app)
            try await wrInsertAssignment(testSetupID: "setup_followup_run", title: "Run Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_followup_run", testSetupID: "setup_followup_run", userID: student.requireID(),
                status: "running", on: app)

            let html = try await getHTML("/submissions/sub_followup_run", cookie: cookie, on: app)
            #expect(html.contains("data-poll-url=\"/submissions/sub_followup_run?fragment=state\""))
            #expect(html.contains("/table-poll.js"))
            #expect(html.contains("data-pending=\"true\""))

            let fragment = try await getHTML("/submissions/sub_followup_run?fragment=state", cookie: cookie, on: app)
            #expect(fragment.contains("Grading"))
        }
    }

    @Test func theFinalFragmentLinksToTheResultPage() async throws {
        try await withWebRoutesApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrInsertSetup(id: "setup_followup_done", on: app)
            try await wrInsertAssignment(testSetupID: "setup_followup_done", title: "Done Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_followup_done", testSetupID: "setup_followup_done", userID: student.requireID(), on: app)

            let fragment = try await getHTML(
                "/submissions/sub_followup_done?fragment=state", cookie: cookie, on: app)
            #expect(fragment.contains("data-submission-final"))
            #expect(fragment.contains("href=\"/submissions/sub_followup_done\""))
        }
    }
}
