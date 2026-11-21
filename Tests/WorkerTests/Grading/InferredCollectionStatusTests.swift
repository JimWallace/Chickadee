import Core
import Foundation
import Testing

@testable import chickadee_runner

// The one-word job status the daemon reports is derived from the collection's
// counters, and nothing pinned the derivation: the 2026-09 mutation sweep
// flipped every comparison in it and the suite could not tell. Worst outcome
// wins, and a failed build is a failure even with nothing to count.
@Suite struct InferredCollectionStatusTests {

    private func collection(
        buildStatus: BuildStatus = .passed,
        passCount: Int = 0, failCount: Int = 0, errorCount: Int = 0, timeoutCount: Int = 0
    ) -> TestOutcomeCollection {
        TestOutcomeCollection(
            submissionID: "sub", testSetupID: "ts", attemptNumber: 1,
            buildStatus: buildStatus, compilerOutput: nil, outcomes: [],
            totalTests: passCount + failCount + errorCount + timeoutCount,
            passCount: passCount, failCount: failCount, errorCount: errorCount,
            timeoutCount: timeoutCount, executionTimeMs: 0, warnings: [],
            jobStartedAt: nil, runnerVersion: "test", timestamp: Date(timeIntervalSince1970: 0))
    }

    @Test func allPassingIsPassed() {
        #expect(WorkerDaemon.inferredCollectionStatus(collection(passCount: 3)) == .passed)
        #expect(WorkerDaemon.inferredCollectionStatus(collection()) == .passed)
    }

    @Test func oneFailureIsFailed() {
        #expect(WorkerDaemon.inferredCollectionStatus(collection(passCount: 3, failCount: 1)) == .failed)
    }

    @Test func aFailedBuildIsFailedEvenWithNoOutcomes() {
        #expect(WorkerDaemon.inferredCollectionStatus(collection(buildStatus: .failed)) == .failed)
    }

    @Test func errorOutranksFailure() {
        #expect(
            WorkerDaemon.inferredCollectionStatus(collection(failCount: 2, errorCount: 1)) == .error)
        #expect(
            WorkerDaemon.inferredCollectionStatus(collection(buildStatus: .failed, errorCount: 1))
                == .error)
    }

    @Test func timeoutOutranksEverything() {
        #expect(
            WorkerDaemon.inferredCollectionStatus(
                collection(buildStatus: .failed, failCount: 1, errorCount: 1, timeoutCount: 1))
                == .timeout)
    }
}
