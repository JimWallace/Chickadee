// Tests/APITests/TargetedClaimWalkTests.swift
//
// The claim walk honours a job's target runner (`RunnerTargetGate`): another
// runner skips the job and claims the next one, the target claims it, and after
// the fallback time any runner claims it. The walk takes the candidate list
// and the claim step as arguments, as in ClaimWalkTests.

import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class TargetedClaimWalkTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-targetwalk")
    }

    private static let manifest =
        #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[{"tier":"public","script":"tests.py"}],"timeLimitSeconds":10,"makefile":null}"#

    private func candidate(
        id: String, target: String? = nil, queuedSecondsAgo: TimeInterval = 0
    ) throws -> (APISubmission, APITestSetup, TestProperties) {
        let setup = APITestSetup(
            id: "setup_\(id)",
            manifest: Self.manifest,
            zipPath: app.testSetupsDirectory + "setup_\(id).zip",
            courseID: UUID()
        )
        let submission = APISubmission(
            id: id,
            testSetupID: "setup_\(id)",
            zipPath: app.submissionsDirectory + "\(id).zip",
            attemptNumber: 1,
            status: SubmissionStatus.pending.rawValue,
            kind: APISubmission.Kind.validation
        )
        submission.targetRunnerID = target
        submission.submittedAt = Date().addingTimeInterval(-queuedSecondsAgo)
        let manifestData = try #require(Self.manifest.data(using: .utf8))
        return (submission, setup, try #require(decodeManifest(from: manifestData)))
    }

    private func payload(workerID: String) -> WorkerActivityPayload {
        WorkerActivityPayload(
            workerID: workerID,
            hostname: "host-\(workerID)",
            runnerVersion: "0.5.512",
            maxConcurrentJobs: 1,
            activeJobs: 0,
            profile: nil
        )
    }

    private var evaluator: ClaimEvaluator {
        ClaimEvaluator(
            assignmentRequirements: app.assignmentRequirements,
            compatibilityMatcher: CompatibilityMatcher(),
            db: app.db,
            application: app,
            logger: app.logger
        )
    }

    /// Runs the walk for `runner`; every claim it attempts succeeds.
    private func walk(
        _ candidates: [(APISubmission, APITestSetup, TestProperties)], runner: String
    ) async throws -> (claimed: String?, attempted: [String]) {
        var attempted: [String] = []
        let claimed = try await evaluateAndClaimCandidate(
            candidates: candidates,
            body: payload(workerID: runner),
            runnerProfile: nil,
            evaluator: evaluator,
            claim: { id in
                attempted.append(id)
                return candidates.first { $0.0.id == id }?.0
            }
        )
        return (claimed?.submission.id, attempted)
    }

    @Test func anotherRunnerSkipsATargetedJobAndClaimsTheNext() async throws {
        try await withApp(app) { _ in
            let candidates = [
                try candidate(id: "sub_for_starling", target: "Starling"),
                try candidate(id: "sub_for_anyone"),
            ]
            let result = try await walk(candidates, runner: "Sparrow")
            #expect(result.attempted == ["sub_for_anyone"])
            #expect(result.claimed == "sub_for_anyone")
        }
    }

    @Test func theTargetClaimsItsJob() async throws {
        try await withApp(app) { _ in
            let candidates = [try candidate(id: "sub_for_starling", target: "Starling")]
            let result = try await walk(candidates, runner: "Starling")
            #expect(result.claimed == "sub_for_starling")
        }
    }

    @Test func anotherRunnerClaimsATargetedJobAfterTheFallbackTime() async throws {
        try await withApp(app) { _ in
            let candidates = [
                try candidate(
                    id: "sub_waited", target: "Starling",
                    queuedSecondsAgo: RunnerTargetGate.fallbackSeconds + 1)
            ]
            let result = try await walk(candidates, runner: "Sparrow")
            #expect(result.claimed == "sub_waited")
        }
    }

    /// A target does not make a runner claim a job it cannot grade.
    @Test func theTargetStillPassesTheCompatibilityCheck() async throws {
        try await withApp(app) { _ in
            let (submission, setup, manifest) = try candidate(id: "sub_gated", target: "Starling")
            var gated = manifest
            gated.minimumRunnerVersion = "99.0.0"
            let result = try await walk([(submission, setup, gated)], runner: "Starling")
            #expect(result.claimed == nil)
            #expect(result.attempted.isEmpty)
        }
    }
}
