// Tests/APITests/Pages/ResultPageAuditFixTests.swift
//
// The result-page findings of UI audit #3007: the count tiles partition the
// tests (finding 2), the pending band names its state and polls through
// `table-poll.js` (finding 1), the page names the assignment and attempt
// rather than a database ID (finding 3), and every view reads one display
// map for submission and assignment states (findings 4 and 9).

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct ResultCountTilesTests {

    private static let skipText = "Skipped: prerequisite 'test_build.py' did not pass"

    @Test func aDependencySkipCountsOnceAsSkipped() {
        let collection = wrMakeCollection(
            submissionID: "s",
            outcomes: [
                wrMakeOutcome(name: "a", status: .pass),
                wrMakeOutcome(name: "b", status: .fail),
                wrMakeOutcome(name: "c", status: .fail, shortResult: Self.skipText),
                wrMakeOutcome(name: "d", status: .error),
                wrMakeOutcome(name: "e", status: .timeout),
            ])
        let tiles = ResultCountTiles(collection: collection)
        #expect(tiles == ResultCountTiles(failed: 1, errors: 1, timedOut: 1, skipped: 1))
        #expect(collection.passCount + tiles.failed + tiles.errors + tiles.timedOut + tiles.skipped == 5)
    }

    @Test func aCollectionWithoutOutcomesKeepsItsOwnCounts() {
        let collection = TestOutcomeCollection(
            submissionID: "s", testSetupID: "t", attemptNumber: 1, buildStatus: .passed, compilerOutput: nil,
            outcomes: [], totalTests: 4, passCount: 1, failCount: 2, errorCount: 1, timeoutCount: 0,
            executionTimeMs: 0, warnings: [], runnerVersion: "r", timestamp: Date(timeIntervalSince1970: 0))
        #expect(
            ResultCountTiles(collection: collection) == ResultCountTiles(failed: 2, errors: 1, timedOut: 0, skipped: 0))
    }
}

@Suite struct StateDisplayMapTests {

    @Test(arguments: [
        (SubmissionStatus.pending, "Queued"), (.assigned, "Grading"), (.running, "Grading"),
        (.complete, "Graded"), (.failed, "Grading failed"),
    ])
    func submissionStatusLabel(status: SubmissionStatus, label: String) {
        #expect(status.displayLabel == label)
        #expect(!status.displayLabel.lowercased().contains("runner"))
    }

    @Test func onlyTheWaitingStatesPoll() {
        #expect(SubmissionStatus.allCasesForTest.filter(\.awaitsResult) == [.pending, .assigned, .running])
    }

    @Test func previewIsStaffOnlyEverywhere() {
        #expect(AssignmentVisibility.preview.displayLabel == "staff only")
        #expect(AssignmentVisibility.displayLabel(forRaw: "preview") == "staff only")
        #expect(AssignmentVisibility.displayLabel(forRaw: "closed") == "closed")
    }

    @Test func thePendingRegionNamesItsStateAndAFinalOneAsksForAReload() {
        let queued = SubmissionStateRegion(status: .pending).render()
        #expect(queued.contains("Queued"))
        #expect(!queued.contains("data-submission-final"))
        let grading = SubmissionStateRegion(status: .assigned).render()
        #expect(grading.contains("Grading"))
        let done = SubmissionStateRegion(status: .complete).render()
        #expect(done.contains("data-submission-final"))
    }

    @Test func errorTitlesArePlainLanguage() {
        #expect(errorPageTitle(for: .notFound) == "Page not found")
        #expect(errorPageTitle(for: .unprocessableEntity) == "Request not understood")
        #expect(errorPageTitle(for: .internalServerError) == "Something went wrong")
    }
}

extension SubmissionStatus {
    /// The enum is not `CaseIterable`; the test lists every case once.
    fileprivate static var allCasesForTest: [SubmissionStatus] {
        [.pending, .assigned, .running, .complete, .failed, .arena]
    }
}

@Suite(.serialized, .timeLimit(.minutes(5))) struct ResultPageRouteAuditTests {

    @Test func aPendingSubmissionShowsItsStateInAPolledRegion() async throws {
        try await withWebRoutesApp { app in
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
        try await withWebRoutesApp { app in
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
