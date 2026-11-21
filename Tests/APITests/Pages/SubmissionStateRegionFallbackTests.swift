// Tests/APITests/Pages/SubmissionStateRegionFallbackTests.swift
//
// A follow-up from the review of the UI audit #3007 fixes: the final
// pending-band state carries a plain link to the results, so a reader is
// not stuck when the automatic reload does not happen.

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
