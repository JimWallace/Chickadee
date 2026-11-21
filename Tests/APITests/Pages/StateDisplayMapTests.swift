// Tests/APITests/Pages/StateDisplayMapTests.swift
//
// Every view reads one display map for submission and assignment states
// (UI audit #3007, findings 4 and 9), and the pending band names its state
// (finding 1).

import Core
import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

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
