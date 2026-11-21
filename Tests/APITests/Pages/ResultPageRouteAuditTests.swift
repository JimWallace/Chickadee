// Tests/APITests/Pages/ResultPageRouteAuditTests.swift
//
// The result-page findings of UI audit #3007, through the route: the
// pending band names its state and polls through `table-poll.js` (finding
// 1), the count tiles partition the rows (finding 2), and the page names
// the assignment and attempt rather than a database ID (finding 3).

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct ResultPageRouteAuditTests {

    @Test func aPendingSubmissionShowsItsStateInAPolledRegion() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrInsertSetup(id: "setup_audit_pend", on: app)
            try await wrInsertAssignment(testSetupID: "setup_audit_pend", title: "Audit Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_audit_pend", testSetupID: "setup_audit_pend", userID: student.requireID(),
                status: "assigned", on: app)

            let html = try await getHTML("/submissions/sub_audit_pend", cookie: cookie, on: app)
            #expect(html.contains("data-poll-url=\"/submissions/sub_audit_pend?fragment=state\""))
            #expect(html.contains("data-poll-swap=\"region\""))
            #expect(html.contains("/table-poll.js"))
            #expect(html.contains("Grading"))
            #expect(!html.contains("Waiting for a runner"))
            #expect(html.contains("<title>Audit Lab — Attempt 1"))
            #expect(!html.contains("<title>Submission sub_audit_pend"))
            #expect(html.contains("/testsetups/setup_audit_pend/history"))

            let fragment = try await getHTML("/submissions/sub_audit_pend?fragment=state", cookie: cookie, on: app)
            #expect(fragment.contains("Grading"))
            #expect(!fragment.contains("<html"))
        }
    }

    @Test func theTilesPartitionTheRowsAndShowTimeouts() async throws {
        try await withTestApp { app in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            try await wrInsertSetup(id: "setup_audit_tiles", on: app)
            try await wrInsertAssignment(testSetupID: "setup_audit_tiles", title: "Tiles Lab", isOpen: true, on: app)
            try await wrInsertSubmission(
                id: "sub_audit_tiles", testSetupID: "setup_audit_tiles", userID: student.requireID(), on: app)
            try await wrInsertResult(
                submissionID: "sub_audit_tiles",
                outcomes: [
                    wrMakeOutcome(name: "a.sh", status: .fail),
                    wrMakeOutcome(
                        name: "b.sh", status: .fail,
                        shortResult: "Skipped: prerequisite 'a.sh' did not pass"),
                    wrMakeOutcome(name: "c.sh", status: .timeout),
                ],
                on: app)

            let html = try await getHTML("/submissions/sub_audit_tiles", cookie: cookie, on: app)
            #expect(html.contains("Timed out"))
            #expect(Self.tile("Failed", in: html) == "1")
            #expect(Self.tile("Skipped", in: html) == "1")
            #expect(Self.tile("Timed out", in: html) == "1")
        }
    }

    /// The value shown in the count tile labelled `label`.
    private static func tile(_ label: String, in html: String) -> String? {
        guard let labelRange = html.range(of: "<div class=\"diagnostic-label\">\(label)</div>") else { return nil }
        let before = html[..<labelRange.lowerBound]
        guard let close = before.range(of: "</div>", options: .backwards) else { return nil }
        guard let open = before[..<close.lowerBound].range(of: ">", options: .backwards) else { return nil }
        return String(before[open.upperBound..<close.lowerBound])
    }
}
