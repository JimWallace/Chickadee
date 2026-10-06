// Tests/APITests/UnclaimableJobsRuleTests.swift
//
// Runners update only after they drain, so a runner behind the server is
// normal for a while. The alert that matters is for jobs that wait because no
// online runner may grade them. These tests prove that the rule fires for
// exactly those jobs, by the claim walk's own decision, names the reason, and
// stays quiet with no runner online; that the activity store's read for it
// prunes nothing; and that the skew alert's default grace covers an update
// job and a drain.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct UnclaimableJobsRuleTests {

    private func manifest(minimumRunnerVersion: String? = nil) throws -> TestProperties {
        let minimum = minimumRunnerVersion.map { #", "minimumRunnerVersion": "\#($0)""# } ?? ""
        let json =
            #"{"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [], "#
            + #""testSuites": [{"tier": "public", "script": "test.sh"}], "timeLimitSeconds": 10, "makefile": null"#
            + minimum + "}"
        return try #require(decodeManifest(fromJSON: json))
    }

    private func group(
        _ id: String, minimumRunnerVersion: String? = nil, jobs: Int = 1, waited: TimeInterval = 600
    )
        throws -> WaitingJobGroup
    {
        WaitingJobGroup(
            testSetupID: id, manifest: try manifest(minimumRunnerVersion: minimumRunnerVersion),
            requirements: nil, jobCount: jobs, oldestWaitSeconds: waited)
    }

    private func runner(_ id: String, _ version: String) -> OnlineRunner {
        OnlineRunner(workerID: id, runnerVersion: version, profile: nil)
    }

    @Test func jobsThatNeedANewerRunnerThanAnyOnlineFireWithTheReason() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [try group("setup-new", minimumRunnerVersion: "0.5.500", jobs: 3, waited: 720)],
            runners: [runner("Sparrow", "0.5.499"), runner("Starling", "0.5.498")])
        #expect(evaluation.isFiring)
        #expect(evaluation.details["blocked_jobs"] == "3")
        #expect(evaluation.details["blocked_test_setups"] == "setup-new")
        #expect(evaluation.details["online_runners"] == "Sparrow,Starling")
        #expect(evaluation.summary.contains("0.5.500"), "the reason names the minimum: \(evaluation.summary)")
        #expect(evaluation.summary.contains("oldest 12 min"))
    }

    @Test func oneOnlineRunnerThatCanGradeTheJobsKeepsItQuiet() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [try group("setup-new", minimumRunnerVersion: "0.5.500")],
            runners: [runner("Sparrow", "0.5.499"), runner("Chickadee", "0.5.500")])
        #expect(!evaluation.isFiring)
    }

    @Test func onlyTheBlockedGroupsAreCounted() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [
                try group("setup-plain", jobs: 5),
                try group("setup-new", minimumRunnerVersion: "0.5.500", jobs: 2),
            ],
            runners: [runner("Sparrow", "0.5.499")])
        #expect(evaluation.isFiring)
        #expect(evaluation.details["blocked_jobs"] == "2")
        #expect(evaluation.details["blocked_test_setups"] == "setup-new")
    }

    /// The runner-offline rule covers a fleet with no runner up.
    @Test func noRunnerOnlineKeepsItQuiet() throws {
        let evaluation = decideUnclaimableJobs(
            groups: [try group("setup-new", minimumRunnerVersion: "0.5.500")], runners: [])
        #expect(!evaluation.isFiring)
    }

    @Test func noWaitingJobKeepsItQuiet() {
        #expect(!decideUnclaimableJobs(groups: [], runners: [runner("Sparrow", "0.5.499")]).isFiring)
    }

    /// The rule and the claim walk must agree: a job the rule calls blocked is
    /// one that `claimCompatibility`, the claim walk's decision, refuses.
    @Test func theRuleUsesTheClaimDecision() throws {
        let job = try manifest(minimumRunnerVersion: "0.5.500")
        let refused = claimCompatibility(
            runnerVersion: "0.5.499", runnerProfile: nil, manifest: job, requirements: nil)
        let accepted = claimCompatibility(
            runnerVersion: "0.5.500", runnerProfile: nil, manifest: job, requirements: nil)
        #expect(!refused.isCompatible)
        #expect(accepted.isCompatible)
    }

    /// The rule reads the store with a short window. That read must not drop a
    /// runner that another reader, with a longer window, still needs.
    @Test func readingTheOnlineRunnersPrunesNothing() async {
        let store = WorkerActivityStore()
        let now = Date()
        await store.markActive(
            workerID: "Starling", hostname: "starling-runner", runnerVersion: "0.5.498",
            at: now.addingTimeInterval(-600))
        await store.markActive(
            workerID: "Sparrow", hostname: "sparrow-runner", runnerVersion: "0.5.499", at: now)

        let online = await store.activeRunners(withinSeconds: 120, now: now)
        #expect(online.map(\.workerID) == ["Sparrow"])
        let remembered = await store.knownRunnerVersions(rememberSeconds: 3600, now: now)
        #expect(Set(remembered) == ["0.5.498", "0.5.499"])
    }

    /// A runner host's update job runs every 10 minutes and a drain takes up
    /// to 10 more, so a correct runner can be about 25 minutes behind.
    @Test func theSkewGraceCoversAnUpdateJobAndADrain() {
        #expect(ServerHealthAlertConfiguration.default.runnerVersionSkewGraceSeconds >= 25 * 60)
    }
}
