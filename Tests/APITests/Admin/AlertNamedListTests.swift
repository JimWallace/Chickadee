import Foundation
import Testing

@testable import APIServer

/// Every alert that names runners or assignments lists at most
/// `alertNamedListLimit` of them, then ", and N more", and keeps the full list
/// in its details.
@Suite struct AlertNamedListTests {

    @Test func theListStopsAtTheLimit() {
        #expect(alertNamedList(["A", "B"]) == "A, B")
        #expect(alertNamedList((1...7).map { "R\($0)" }) == "R1, R2, R3, R4, R5, and 2 more")
    }

    @Test func runnerOfflineCapsTheSummaryAndKeepsEveryNameInDetails() {
        let names = (1...7).map { "R\($0)" }
        let evaluation = decideRunnerOffline(
            pending: .empty,
            presence: RunnerPresenceState(recentWithinOffline: false, anyKnownRunner: true),
            offlineSeconds: 300,
            quietRunners: names
        )
        #expect(evaluation.summary.contains("(last seen: R1, R2, R3, R4, R5, and 2 more)"))
        #expect(evaluation.details["quiet_runners"] == names.joined(separator: ", "))
    }

    @Test func brightspaceCapsTheAssignments() {
        let titles = (1...6).map { "Lab \($0)" }
        let evaluation = decideBrightspaceSyncFailing(
            errorCount: 6, threshold: 3, windowMinutes: 60, lastDetail: nil, assignmentTitles: titles)
        #expect(evaluation.summary.contains("for Lab 1, Lab 2, Lab 3, Lab 4, Lab 5, and 1 more,"))
        #expect(evaluation.details["assignments"] == titles.joined(separator: ", "))
    }

    @Test func unclaimableJobsListsASetupWithNoAssignmentByItsID() throws {
        let json =
            #"{"schemaVersion": 1, "gradingMode": "worker", "requiredFiles": [], "#
            + #""testSuites": [{"tier": "public", "script": "test.sh"}], "timeLimitSeconds": 10, "#
            + #""makefile": null, "minimumRunnerVersion": "0.5.500"}"#
        let manifest = try #require(decodeManifest(fromJSON: json))
        let groups = [
            WaitingJobGroup(
                testSetupID: "setup-a", manifest: manifest, requirements: nil, jobCount: 1,
                oldestWaitSeconds: 600, assignmentTitle: "Lab 5"),
            WaitingJobGroup(
                testSetupID: "setup-b", manifest: manifest, requirements: nil, jobCount: 1,
                oldestWaitSeconds: 600),
        ]
        let evaluation = decideUnclaimableJobs(
            groups: groups, runners: [OnlineRunner(workerID: "Sparrow", runnerVersion: "0.5.499", profile: nil)])
        #expect(evaluation.summary.hasPrefix("2 submissions for Lab 5, test setup setup-b wait"))
        #expect(evaluation.details["assignments"] == "Lab 5; test setup setup-b")
    }
}
