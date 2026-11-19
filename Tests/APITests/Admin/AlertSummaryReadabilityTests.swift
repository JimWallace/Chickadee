import Core
import Foundation
import Testing

@testable import APIServer

/// Each health alert's summary says what is wrong, names what it is about where
/// the rule knows it, uses units a person reads (minutes, not seconds), and says
/// where to look. In Nov 2026 "1 runner(s) behind server" paged for four days
/// without naming Sparrow; these tests hold the other rules to the same bar.
@Suite struct AlertSummaryReadabilityTests {

    @Test func runnerOfflineNamesTheRunnersInMinutes() {
        let evaluation = decideRunnerOffline(
            pending: PendingQueueState(pendingCount: 3, oldestPendingAge: 400),
            presence: RunnerPresenceState(recentWithinOffline: false, anyKnownRunner: true),
            offlineSeconds: 600,
            quietRunners: ["Hawk", "Sparrow"]
        )
        #expect(evaluation.isFiring)
        #expect(
            evaluation.summary
                == "No runner has checked in for 10m (last seen: Hawk, Sparrow); "
                + "3 submissions are waiting to be graded. Nothing is grading. Check the runner hosts and their logs.")
        #expect(evaluation.details["quiet_runners"] == "Hawk, Sparrow")
    }

    @Test func runnerOfflineWithoutNamesOrQueueStillReads() {
        let evaluation = decideRunnerOffline(
            pending: .empty,
            presence: RunnerPresenceState(recentWithinOffline: false, anyKnownRunner: true),
            offlineSeconds: 300
        )
        #expect(evaluation.summary.hasPrefix("No runner has checked in for 5m. Nothing is grading."))
    }

    @Test func editorKernelUnrecoverableSaysWhatStudentsSaw() {
        let evaluation = decideEditorKernelUnrecoverable(failedCount: 1, threshold: 1, windowMinutes: 30)
        #expect(evaluation.summary.hasPrefix("1 student in the last 30 min could not use the notebook editor"))
        #expect(!evaluation.summary.contains("recover_failed"))
        #expect(evaluation.summary.contains("get_browser_diagnostics"))
    }

    @Test func brightspaceSyncFailingNamesTheAssignments() {
        let evaluation = decideBrightspaceSyncFailing(
            errorCount: 4, threshold: 3, windowMinutes: 60, lastDetail: "HTTP 503",
            assignmentTitles: ["Lab 3", "Lab 4"])
        #expect(
            evaluation.summary
                == "4 grade pushes to BrightSpace failed in the last 60 min for Lab 3, Lab 4, "
                + "so those grades are not in LEARN. The latest error: HTTP 503. "
                + "Check the course's BrightSpace page.")
        #expect(evaluation.details["assignments"] == "Lab 3, Lab 4")
    }

    @Test func unclaimableJobsNamesTheAssignment() throws {
        let json =
            #"{"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [], "#
            + #""testSuites": [{"tier": "public", "script": "test.sh"}], "timeLimitSeconds": 10, "#
            + #""makefile": null, "minimumRunnerVersion": "0.5.500"}"#
        let manifest = try #require(decodeManifest(fromJSON: json))
        let group = WaitingJobGroup(
            testSetupID: "setup-1", manifest: manifest, requirements: nil, jobCount: 2,
            oldestWaitSeconds: 720, assignmentTitle: "Lab 5")
        let evaluation = decideUnclaimableJobs(
            groups: [group], runners: [OnlineRunner(workerID: "Sparrow", runnerVersion: "0.5.499", profile: nil)])
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.hasPrefix("2 submissions for Lab 5 wait with no online runner that can grade them"))
        #expect(evaluation.summary.contains("oldest 12 min"))
    }

    @Test func deployerUnhealthySaysWhereToLook() {
        let status = DeployerStatus(
            state: "stuck", detail: "v0.5.900 failed 5 times", deployedVersion: "0.5.899",
            latestSeen: "v0.5.900", paused: false,
            updatedAt: ISO8601DateFormatter().string(from: Date()))
        let evaluation = decideDeployerUnhealthy(status: status, now: Date())
        #expect(evaluation.summary.contains("Production is not taking new releases"))
        #expect(evaluation.summary.contains("chickadee-deployer"))
    }

    @Test func versionSkewThresholdIsInMinutes() {
        #expect(HealthRule.runnerVersionSkew.thresholdText(.default) == "a runner stays behind the server for 30 min")
    }
}
