// Tests/APITests/Pages/RunningSubmissionPollTests.swift
//
// A follow-up from the review of the UI audit #3007 fixes: the result page
// and the state poller share one definition of "waiting"
// (`SubmissionStatus.awaitsResult`), so a page first loaded in `.running`
// polls too, and the final fragment links to the result page.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

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
