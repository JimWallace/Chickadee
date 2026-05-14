import XCTest

@testable import Core
@testable import chickadee_server

final class StageTimingAggregatorTests: XCTestCase {

    func testInitFromNilLeavesEveryStageNil() {
        let aggregator = StageTimingAggregator(from: nil)

        XCTAssertNil(aggregator.workdirSetupMs)
        XCTAssertNil(aggregator.submissionDirSetupMs)
        XCTAssertNil(aggregator.submissionDownloadMs)
        XCTAssertNil(aggregator.testSetupAcquireMs)
        XCTAssertNil(aggregator.submissionUnpackMs)
        XCTAssertNil(aggregator.starterCleanupMs)
        XCTAssertNil(aggregator.submissionPrepareMs)
        XCTAssertNil(aggregator.makeStepMs)
        XCTAssertNil(aggregator.runtimeHelperSetupMs)
        XCTAssertNil(aggregator.testExecutionMs)
        XCTAssertNil(aggregator.totalKnownStageMs)
    }

    func testInitFromPopulatedTimingsCopiesEveryField() {
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

        XCTAssertEqual(aggregator.workdirSetupMs, 1)
        XCTAssertEqual(aggregator.submissionDirSetupMs, 2)
        XCTAssertEqual(aggregator.submissionDownloadMs, 3)
        XCTAssertEqual(aggregator.testSetupAcquireMs, 4)
        XCTAssertEqual(aggregator.submissionUnpackMs, 5)
        XCTAssertEqual(aggregator.starterCleanupMs, 6)
        XCTAssertEqual(aggregator.submissionPrepareMs, 7)
        XCTAssertEqual(aggregator.makeStepMs, 8)
        XCTAssertEqual(aggregator.runtimeHelperSetupMs, 9)
        XCTAssertEqual(aggregator.testExecutionMs, 10)
    }

    func testApplyToMetricCopiesPopulatedFields() {
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

        XCTAssertEqual(metric.workdirSetupMs, 11)
        XCTAssertEqual(metric.submissionDirSetupMs, 12)
        XCTAssertEqual(metric.submissionDownloadMs, 13)
        XCTAssertEqual(metric.testSetupAcquireMs, 14)
        XCTAssertEqual(metric.submissionUnpackMs, 15)
        XCTAssertEqual(metric.starterCleanupMs, 16)
        XCTAssertEqual(metric.submissionPrepareMs, 17)
        XCTAssertEqual(metric.makeStepMs, 18)
        XCTAssertEqual(metric.runtimeHelperSetupMs, 19)
        XCTAssertEqual(metric.testExecutionMs, 20)
    }

    func testApplyFromNilTimingsClearsExistingStageFields() {
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

        XCTAssertNil(metric.workdirSetupMs)
        XCTAssertNil(metric.submissionDirSetupMs)
        XCTAssertNil(metric.submissionDownloadMs)
        XCTAssertNil(metric.testSetupAcquireMs)
        XCTAssertNil(metric.submissionUnpackMs)
        XCTAssertNil(metric.starterCleanupMs)
        XCTAssertNil(metric.submissionPrepareMs)
        XCTAssertNil(metric.makeStepMs)
        XCTAssertNil(metric.runtimeHelperSetupMs)
        XCTAssertNil(metric.testExecutionMs)
    }

    func testTotalKnownStageMsSumsPopulatedStagesIgnoringNils() {
        let timings = WorkerExecutionStageTimings(
            workdirSetupMs: 12,
            submissionDownloadMs: 45,
            testSetupAcquireMs: 67,
            submissionPrepareMs: 89,
            testExecutionMs: 100
        )

        let aggregator = StageTimingAggregator(from: timings)

        XCTAssertEqual(aggregator.totalKnownStageMs, 12 + 45 + 67 + 89 + 100)
    }

    func testTotalKnownStageMsIsNilWhenEveryStageIsNil() {
        let aggregator = StageTimingAggregator(from: WorkerExecutionStageTimings())

        XCTAssertNil(aggregator.totalKnownStageMs)
    }
}
