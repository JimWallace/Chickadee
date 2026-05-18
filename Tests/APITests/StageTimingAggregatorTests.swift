import Testing

@testable import Core
@testable import chickadee_server

@Suite struct StageTimingAggregatorTests {

    @Test func initFromNilLeavesEveryStageNil() {
        let aggregator = StageTimingAggregator(from: nil)

        #expect(aggregator.workdirSetupMs == nil)
        #expect(aggregator.submissionDirSetupMs == nil)
        #expect(aggregator.submissionDownloadMs == nil)
        #expect(aggregator.testSetupAcquireMs == nil)
        #expect(aggregator.submissionUnpackMs == nil)
        #expect(aggregator.starterCleanupMs == nil)
        #expect(aggregator.submissionPrepareMs == nil)
        #expect(aggregator.makeStepMs == nil)
        #expect(aggregator.runtimeHelperSetupMs == nil)
        #expect(aggregator.testExecutionMs == nil)
        #expect(aggregator.totalKnownStageMs == nil)
    }

    @Test func initFromPopulatedTimingsCopiesEveryField() {
        let timings = WorkerExecutionStageTimings(
            workdirSetupMs: 1,
            submissionDirSetupMs: 2,
            submissionDownloadMs: 3,
            testSetupAcquireMs: 4,
            submissionUnpackMs: 5,
            starterCleanupMs: 6,
            submissionPrepareMs: 7,
            makeStepMs: 8,
            runtimeHelperSetupMs: 9,
            testExecutionMs: 10
        )

        let aggregator = StageTimingAggregator(from: timings)

        #expect(aggregator.workdirSetupMs == 1)
        #expect(aggregator.submissionDirSetupMs == 2)
        #expect(aggregator.submissionDownloadMs == 3)
        #expect(aggregator.testSetupAcquireMs == 4)
        #expect(aggregator.submissionUnpackMs == 5)
        #expect(aggregator.starterCleanupMs == 6)
        #expect(aggregator.submissionPrepareMs == 7)
        #expect(aggregator.makeStepMs == 8)
        #expect(aggregator.runtimeHelperSetupMs == 9)
        #expect(aggregator.testExecutionMs == 10)
    }

    @Test func applyToMetricCopiesPopulatedFields() {
        let timings = WorkerExecutionStageTimings(
            workdirSetupMs: 11,
            submissionDirSetupMs: 12,
            submissionDownloadMs: 13,
            testSetupAcquireMs: 14,
            submissionUnpackMs: 15,
            starterCleanupMs: 16,
            submissionPrepareMs: 17,
            makeStepMs: 18,
            runtimeHelperSetupMs: 19,
            testExecutionMs: 20
        )
        let metric = JobExecutionMetric(
            submissionID: "sub_x",
            jobID: "sub_x",
            testSetupID: "setup_x",
            courseID: nil,
            assignmentID: nil,
            userID: nil,
            runnerID: nil,
            kind: "student",
            attemptNumber: 1,
            enqueuedAt: nil
        )

        StageTimingAggregator(from: timings).apply(to: metric)

        #expect(metric.workdirSetupMs == 11)
        #expect(metric.submissionDirSetupMs == 12)
        #expect(metric.submissionDownloadMs == 13)
        #expect(metric.testSetupAcquireMs == 14)
        #expect(metric.submissionUnpackMs == 15)
        #expect(metric.starterCleanupMs == 16)
        #expect(metric.submissionPrepareMs == 17)
        #expect(metric.makeStepMs == 18)
        #expect(metric.runtimeHelperSetupMs == 19)
        #expect(metric.testExecutionMs == 20)
    }

    @Test func applyFromNilTimingsClearsExistingStageFields() {
        let metric = JobExecutionMetric(
            submissionID: "sub_y",
            jobID: "sub_y",
            testSetupID: "setup_y",
            courseID: nil,
            assignmentID: nil,
            userID: nil,
            runnerID: nil,
            kind: "student",
            attemptNumber: 1,
            enqueuedAt: nil
        )
        metric.workdirSetupMs = 99
        metric.testExecutionMs = 100

        StageTimingAggregator(from: nil).apply(to: metric)

        #expect(metric.workdirSetupMs == nil)
        #expect(metric.submissionDirSetupMs == nil)
        #expect(metric.submissionDownloadMs == nil)
        #expect(metric.testSetupAcquireMs == nil)
        #expect(metric.submissionUnpackMs == nil)
        #expect(metric.starterCleanupMs == nil)
        #expect(metric.submissionPrepareMs == nil)
        #expect(metric.makeStepMs == nil)
        #expect(metric.runtimeHelperSetupMs == nil)
        #expect(metric.testExecutionMs == nil)
    }

    @Test func totalKnownStageMsSumsPopulatedStagesIgnoringNils() {
        let timings = WorkerExecutionStageTimings(
            workdirSetupMs: 12,
            submissionDownloadMs: 45,
            testSetupAcquireMs: 67,
            submissionPrepareMs: 89,
            testExecutionMs: 100
        )

        let aggregator = StageTimingAggregator(from: timings)

        #expect(aggregator.totalKnownStageMs == 12 + 45 + 67 + 89 + 100)
    }

    @Test func totalKnownStageMsIsNilWhenEveryStageIsNil() {
        let aggregator = StageTimingAggregator(from: WorkerExecutionStageTimings())

        #expect(aggregator.totalKnownStageMs == nil)
    }
}
