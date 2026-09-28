// Tests/APITests/GitHub/GitHubSubmissionManifestTests.swift
//
// The `githubSubmission` manifest opt-in (docs/github-submissions.md slice 3):
// absent means off and leaves the bytes alone, a suite rebuild keeps it, the
// runner never sees it, and only a worker-graded assignment offers it.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct GitHubSubmissionManifestTests {
    static let base = #"{"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}"#

    private func decode(_ json: String) throws -> TestProperties {
        try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
    }

    private func encoded(_ props: TestProperties) throws -> String {
        try #require(String(data: try JSONEncoder().encode(props), encoding: .utf8))
    }

    @Test func absentMeansOffAndIsNotWritten() throws {
        let props = try decode(Self.base)
        #expect(!props.githubSubmission)
        #expect(!(try encoded(props)).contains("githubSubmission"))
    }

    @Test func onRoundTrips() throws {
        let props = try decode(#"{"schemaVersion":1,"githubSubmission":true}"#)
        #expect(props.githubSubmission)
        #expect(try decode(try encoded(props)).githubSubmission)
    }

    @Test func runnerManifestDropsIt() throws {
        let props = try decode(#"{"schemaVersion":1,"githubSubmission":true}"#)
        #expect(!props.runnerSanitized().githubSubmission)
        #expect(!(try encoded(props.runnerSanitized())).contains("githubSubmission"))
    }

    @Test func suiteRebuildKeepsIt() throws {
        let props = try decode(#"{"schemaVersion":1,"githubSubmission":true,"submissionMode":"uploadOnly"}"#)
        let rebuilt = try makeWorkerManifestJSON(preserving: props, testSuites: [], language: nil)
        #expect(try decode(rebuilt).githubSubmission)
    }

    @Test func offeredOnlyWhenOnAndGradedOnTheWorker() throws {
        #expect(GitHubSubmissionOffer.isOffered(manifest: try decode(#"{"schemaVersion":1,"githubSubmission":true}"#)))
        #expect(!GitHubSubmissionOffer.isOffered(manifest: try decode(Self.base)))
        #expect(
            !GitHubSubmissionOffer.isOffered(
                manifest: try decode(#"{"schemaVersion":1,"githubSubmission":true,"gradingMode":"browser"}"#)))
        #expect(!GitHubSubmissionOffer.isOffered(manifest: nil))
    }

    @Test func commitSHAMustBeFortyHexDigits() {
        #expect(GitHubCommitSHA.isWellFormed(String(repeating: "a1", count: 20)))
        #expect(!GitHubCommitSHA.isWellFormed("abc1234"))
        #expect(!GitHubCommitSHA.isWellFormed(String(repeating: "g", count: 40)))
        #expect(!GitHubCommitSHA.isWellFormed(String(repeating: "a", count: 39) + "/"))
    }

    @Test func commitSummaryIsTheFirstLineShortened() {
        #expect(GitHubSubmitState.summary(of: "Fix the loop\n\nLonger body") == "Fix the loop")
        let long = String(repeating: "x", count: 100)
        let summary = GitHubSubmitState.summary(of: long)
        #expect(summary.count == GitHubSubmitState.summaryLimit)
        #expect(summary.hasSuffix("…"))
    }

    @Test func commitLinkEscapesNothingAGitHubNameCanHold() {
        #expect(
            GitHubSourceLink.commitURL(repositoryName: "octo-student/lab.1_x", sha: "abc")
                == "https://github.com/octo-student/lab.1_x/commit/abc")
    }
}
