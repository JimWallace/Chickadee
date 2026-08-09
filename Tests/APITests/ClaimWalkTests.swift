// Tests/APITests/ClaimWalkTests.swift
//
// `evaluateAndClaimCandidate` walks the ordered candidate list and claims the
// first one this runner may grade.  Two of its branches were previously
// unreachable from a test: the lost-race `continue` (another runner claimed a
// candidate between our scan and our claim) and the walk-past-a-blocked-
// candidate `continue`, because both depend on what the *claim step* does and
// the claim step was a method on the route collection.
//
// #1253 moved the walk into WorkerClaimEvaluation.swift and made the claim
// step an injected closure, so both branches are now directly drivable.  These
// tests exist because that seam is the reason the move was worth making.
//
// The atomic claim itself is pinned separately by ClaimCompareAndSetTests.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class ClaimWalkTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-claimwalk")
    }

    private static let manifest =
        #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#

    /// Builds a candidate triple without going through the database ordering
    /// query — the walk takes the list as an argument, so the order under test
    /// is the one written here.
    private func candidate(
        id: String, setupID: String
    ) throws -> (
        APISubmission, APITestSetup, TestProperties
    ) {
        let setup = APITestSetup(
            id: setupID,
            manifest: Self.manifest,
            zipPath: app.testSetupsDirectory + "\(setupID).zip",
            courseID: UUID()
        )
        let submission = APISubmission(
            id: id,
            testSetupID: setupID,
            zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1,
            status: SubmissionStatus.pending.rawValue
        )
        let manifestData = try #require(Self.manifest.data(using: .utf8))
        let props = try #require(decodeManifest(from: manifestData))
        return (submission, setup, props)
    }

    private func makeRequest() -> Request {
        Request(
            application: app,
            method: .POST,
            url: URI(path: "/api/v1/worker/request"),
            on: app.eventLoopGroup.next()
        )
    }

    private func payload(workerID: String) -> WorkerActivityPayload {
        WorkerActivityPayload(
            workerID: workerID,
            hostname: "host-\(workerID)",
            runnerVersion: "runner/1.0",
            maxConcurrentJobs: 1,
            activeJobs: 0,
            profile: nil
        )
    }

    private var evaluator: ClaimEvaluator {
        ClaimEvaluator(
            assignmentRequirements: app.assignmentRequirements,
            compatibilityMatcher: CompatibilityMatcher()
        )
    }

    /// A candidate another runner claims between our scan and our claim must
    /// not end the walk — the next candidate may still be ours.  This is the
    /// branch the code comments describe as impossible to trigger
    /// deterministically through the HTTP endpoint.
    @Test func lostRaceOnFirstCandidateFallsThroughToTheNext() async throws {
        try await withApp(app) { _ in
            let candidates = [
                try candidate(id: "sub_walk_taken", setupID: "setup_walk_a"),
                try candidate(id: "sub_walk_ours", setupID: "setup_walk_b"),
            ]

            var attempted: [String] = []
            let claimed = try await evaluateAndClaimCandidate(
                candidates: candidates,
                req: makeRequest(),
                body: payload(workerID: "w1"),
                runnerProfile: nil,
                evaluator: evaluator,
                claim: { id in
                    attempted.append(id)
                    // First candidate was taken by another runner; second is ours.
                    guard id == "sub_walk_ours" else { return nil }
                    return candidates[1].0
                }
            )

            #expect(attempted == ["sub_walk_taken", "sub_walk_ours"])
            #expect(try #require(claimed).submission.id == "sub_walk_ours")
        }
    }

    /// Every candidate lost to another runner: the walk ends empty rather than
    /// handing back a job it did not claim.
    @Test func allCandidatesLostYieldsNoJob() async throws {
        try await withApp(app) { _ in
            let candidates = [
                try candidate(id: "sub_walk_x", setupID: "setup_walk_x"),
                try candidate(id: "sub_walk_y", setupID: "setup_walk_y"),
            ]

            var attempts = 0
            let claimed = try await evaluateAndClaimCandidate(
                candidates: candidates,
                req: makeRequest(),
                body: payload(workerID: "w1"),
                runnerProfile: nil,
                evaluator: evaluator,
                claim: { _ in
                    attempts += 1
                    return nil
                }
            )

            #expect(attempts == 2, "The walk must try every candidate before giving up")
            #expect(claimed == nil)
        }
    }

    /// The claimed job carries the setup and manifest of the candidate that was
    /// actually claimed, not of the first one scanned — a mismatch here would
    /// hand the runner one submission graded against another's test setup.
    @Test func claimedJobCarriesItsOwnSetupAndManifest() async throws {
        try await withApp(app) { _ in
            let candidates = [
                try candidate(id: "sub_walk_first", setupID: "setup_walk_first"),
                try candidate(id: "sub_walk_second", setupID: "setup_walk_second"),
            ]

            let claimed = try await evaluateAndClaimCandidate(
                candidates: candidates,
                req: makeRequest(),
                body: payload(workerID: "w1"),
                runnerProfile: nil,
                evaluator: evaluator,
                claim: { id in id == "sub_walk_second" ? candidates[1].0 : nil }
            )

            let job = try #require(claimed)
            #expect(job.submission.id == "sub_walk_second")
            #expect(job.setup.id == "setup_walk_second")
        }
    }
}
