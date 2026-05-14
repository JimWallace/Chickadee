import Foundation
import XCTest

@testable import chickadee_server

final class MetricBucketAccumulatorsTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - BucketWindow.resolve

    func testResolveClampsHoursToOneToSeventyTwoRange() {
        let low = BucketWindow.resolve(hours: 0, bucketMinutes: 15, defaultHours: 24, now: now)
        XCTAssertEqual(low.hours, 1)

        let high = BucketWindow.resolve(hours: 200, bucketMinutes: 15, defaultHours: 24, now: now)
        XCTAssertEqual(high.hours, 72)
    }

    func testResolveClampsBucketMinutesToOneToSixtyRange() {
        let low = BucketWindow.resolve(hours: 1, bucketMinutes: 0, defaultHours: 24, now: now)
        XCTAssertEqual(low.bucketMinutes, 1)
        XCTAssertEqual(low.window.bucketSeconds, 60)

        let high = BucketWindow.resolve(hours: 1, bucketMinutes: 600, defaultHours: 24, now: now)
        XCTAssertEqual(high.bucketMinutes, 60)
        XCTAssertEqual(high.window.bucketSeconds, 3600)
    }

    func testResolveFallsBackToDefaultsWhenNothingProvided() {
        let resolved = BucketWindow.resolve(hours: nil, bucketMinutes: nil, defaultHours: 6, now: now)
        XCTAssertEqual(resolved.hours, 6)
        XCTAssertEqual(resolved.bucketMinutes, 15)
        XCTAssertEqual(resolved.window.bucketSeconds, 900)
        XCTAssertEqual(resolved.window.bucketCount, (6 * 3600) / 900)
        XCTAssertEqual(resolved.window.windowStart, now.addingTimeInterval(-6 * 3600))
    }

    func testResolveBucketCountRoundsUpWhenWindowIsNotEvenlyDivisible() {
        // 1h with 17-minute buckets -> ceil(3600 / 1020) = 4 buckets
        let resolved = BucketWindow.resolve(hours: 1, bucketMinutes: 17, defaultHours: 24, now: now)
        XCTAssertEqual(resolved.window.bucketCount, 4)
    }

    // MARK: - bucketIndex

    func testBucketIndexReturnsNilForDateBeforeWindowStart() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 15, defaultHours: 24, now: now).window
        XCTAssertNil(window.bucketIndex(for: window.windowStart.addingTimeInterval(-1)))
    }

    func testBucketIndexReturnsNilForDateAtOrBeyondWindowEnd() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 15, defaultHours: 24, now: now).window
        let windowEnd = window.windowStart.addingTimeInterval(Double(window.bucketSeconds * window.bucketCount))
        XCTAssertNil(window.bucketIndex(for: windowEnd))
        XCTAssertNil(window.bucketIndex(for: windowEnd.addingTimeInterval(60)))
    }

    func testBucketIndexReturnsCorrectIndexForDatesInsideWindow() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 15, defaultHours: 24, now: now).window

        XCTAssertEqual(window.bucketIndex(for: window.windowStart), 0)
        XCTAssertEqual(window.bucketIndex(for: window.windowStart.addingTimeInterval(15 * 60 - 1)), 0)
        XCTAssertEqual(window.bucketIndex(for: window.windowStart.addingTimeInterval(15 * 60)), 1)
        XCTAssertEqual(window.bucketIndex(for: window.windowStart.addingTimeInterval(45 * 60)), 3)
    }

    // MARK: - accumulateRunnerSnapshots

    func testAccumulateRunnerSnapshotsSkipsOutOfRangeSamples() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 30, defaultHours: 24, now: now).window
        let inWindow = RunnerSnapshot(
            runnerID: "r1",
            recordedAt: window.windowStart.addingTimeInterval(60),
            activeJobs: 1,
            maxJobs: 4,
            availableCapacity: 3,
            hostname: nil,
            runnerVersion: nil,
            lastPollAt: nil,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        )
        let beforeWindow = RunnerSnapshot(
            runnerID: "r2",
            recordedAt: window.windowStart.addingTimeInterval(-1),
            activeJobs: 2,
            maxJobs: 4,
            availableCapacity: 2,
            hostname: nil,
            runnerVersion: nil,
            lastPollAt: nil,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        )
        let afterWindow = RunnerSnapshot(
            runnerID: "r3",
            recordedAt: window.windowStart.addingTimeInterval(Double(window.bucketSeconds * window.bucketCount + 1)),
            activeJobs: 3,
            maxJobs: 4,
            availableCapacity: 1,
            hostname: nil,
            runnerVersion: nil,
            lastPollAt: nil,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        )

        let buckets = MetricBucketAccumulators.accumulateRunnerSnapshots(
            [inWindow, beforeWindow, afterWindow],
            window: window
        )

        XCTAssertEqual(buckets.count, window.bucketCount)
        XCTAssertEqual(buckets[0].sampleCount, 1)
        XCTAssertEqual(buckets[0].activeRunnerTotal, 1)
        XCTAssertEqual(buckets[0].utilizationValues, [25])
        XCTAssertEqual(buckets[1].sampleCount, 0)
    }

    func testAccumulateRunnerSnapshotsClampsUtilizationToHundred() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 60, defaultHours: 24, now: now).window
        let snapshot = RunnerSnapshot(
            runnerID: "overloaded",
            recordedAt: window.windowStart,
            activeJobs: 9,
            maxJobs: 4,
            availableCapacity: 0,
            hostname: nil,
            runnerVersion: nil,
            lastPollAt: nil,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        )

        let buckets = MetricBucketAccumulators.accumulateRunnerSnapshots([snapshot], window: window)

        XCTAssertEqual(buckets[0].utilizationValues, [100])
    }

    func testAccumulateRunnerSnapshotsSkipsUtilizationWhenMaxJobsIsZero() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 60, defaultHours: 24, now: now).window
        let snapshot = RunnerSnapshot(
            runnerID: "idle",
            recordedAt: window.windowStart,
            activeJobs: 0,
            maxJobs: 0,
            availableCapacity: 0,
            hostname: nil,
            runnerVersion: nil,
            lastPollAt: nil,
            lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil
        )

        let buckets = MetricBucketAccumulators.accumulateRunnerSnapshots([snapshot], window: window)

        XCTAssertEqual(buckets[0].sampleCount, 1)
        XCTAssertEqual(buckets[0].activeRunnerTotal, 1)
        XCTAssertTrue(buckets[0].utilizationValues.isEmpty)
    }

    // MARK: - accumulateRequestMetrics

    func testAccumulateRequestMetricsCollectsDurations() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 30, defaultHours: 24, now: now).window
        let bucket0 = makeRequestMetric(at: window.windowStart, durationMs: 50)
        let bucket0Again = makeRequestMetric(at: window.windowStart.addingTimeInterval(60), durationMs: 75)
        let bucket1 = makeRequestMetric(at: window.windowStart.addingTimeInterval(31 * 60), durationMs: 200)
        let outOfRange = makeRequestMetric(at: window.windowStart.addingTimeInterval(-5), durationMs: 999)

        let buckets = MetricBucketAccumulators.accumulateRequestMetrics(
            [bucket0, bucket0Again, bucket1, outOfRange],
            window: window
        )

        XCTAssertEqual(buckets[0].requestCount, 2)
        XCTAssertEqual(buckets[0].durationValues.sorted(), [50, 75])
        XCTAssertEqual(buckets[1].requestCount, 1)
        XCTAssertEqual(buckets[1].durationValues, [200])
    }

    // MARK: - accumulateJobMetrics

    func testAccumulateJobMetricsRoutesEachStatusToTheCorrectCounter() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 60, defaultHours: 24, now: now).window
        let metrics = [
            makeJobMetric(completedAt: window.windowStart, status: JobFinalStatus.passed.rawValue),
            makeJobMetric(completedAt: window.windowStart, status: JobFinalStatus.failed.rawValue),
            makeJobMetric(completedAt: window.windowStart, status: JobFinalStatus.error.rawValue),
            makeJobMetric(completedAt: window.windowStart, status: JobFinalStatus.timeout.rawValue),
            makeJobMetric(completedAt: window.windowStart, status: "unrecognized"),
            makeJobMetric(completedAt: window.windowStart, status: nil),
        ]

        let buckets = MetricBucketAccumulators.accumulateJobMetrics(metrics, window: window)

        XCTAssertEqual(buckets[0].completedJobs, 6)
        XCTAssertEqual(buckets[0].passedCount, 1)
        XCTAssertEqual(buckets[0].failedCount, 1)
        XCTAssertEqual(buckets[0].errorCount, 1)
        XCTAssertEqual(buckets[0].timeoutCount, 1)
    }

    func testAccumulateJobMetricsSkipsRowsWithoutCompletedAt() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 60, defaultHours: 24, now: now).window
        let metric = makeJobMetric(completedAt: nil, status: JobFinalStatus.passed.rawValue)

        let buckets = MetricBucketAccumulators.accumulateJobMetrics([metric], window: window)

        XCTAssertEqual(buckets[0].completedJobs, 0)
        XCTAssertEqual(buckets[0].passedCount, 0)
    }

    func testAccumulateJobMetricsCollectsTimingValues() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 60, defaultHours: 24, now: now).window
        let metric = makeJobMetric(
            completedAt: window.windowStart,
            status: JobFinalStatus.passed.rawValue,
            queueWaitMs: 250,
            executionMs: 1_750
        )
        let metricNoTimings = makeJobMetric(
            completedAt: window.windowStart,
            status: JobFinalStatus.passed.rawValue
        )

        let buckets = MetricBucketAccumulators.accumulateJobMetrics([metric, metricNoTimings], window: window)

        XCTAssertEqual(buckets[0].queueWaitValues, [250])
        XCTAssertEqual(buckets[0].executionValues, [1_750])
    }

    // MARK: - buildBucketResponses

    func testBuildBucketResponsesProducesExpectedBucketStartsAndAggregates() {
        let resolved = BucketWindow.resolve(hours: 1, bucketMinutes: 30, defaultHours: 24, now: now)
        let window = resolved.window

        var runners = Array(repeating: RunnerBucketAccumulator(), count: window.bucketCount)
        runners[0].sampleCount = 2
        runners[0].activeRunnerTotal = 5  // avg = round(2.5) = 3
        runners[0].utilizationValues = [40, 60, 80]

        var requests = Array(repeating: RequestBucketAccumulator(), count: window.bucketCount)
        requests[1].requestCount = 1
        requests[1].durationValues = [123]

        var jobs = Array(repeating: JobBucketAccumulator(), count: window.bucketCount)
        jobs[0].completedJobs = 4
        jobs[0].passedCount = 3
        jobs[0].failedCount = 1
        jobs[0].queueWaitValues = [100, 200, 300]
        jobs[0].executionValues = [10, 20, 30]

        let buckets = MetricBucketAccumulators.buildBucketResponses(
            window: window,
            runners: runners,
            requests: requests,
            jobs: jobs
        )

        XCTAssertEqual(buckets.count, window.bucketCount)
        XCTAssertEqual(buckets[0].bucketStart, window.windowStart)
        XCTAssertEqual(buckets[1].bucketStart, window.windowStart.addingTimeInterval(Double(window.bucketSeconds)))

        XCTAssertEqual(buckets[0].avgActiveRunners, 3)
        XCTAssertEqual(buckets[0].avgRunnerUtilizationPercent, 60)  // average(40, 60, 80) = 60
        XCTAssertEqual(buckets[0].maxRunnerUtilizationPercent, 80)
        XCTAssertEqual(buckets[0].completedJobs, 4)
        XCTAssertEqual(buckets[0].passedCount, 3)
        XCTAssertEqual(buckets[0].failedCount, 1)
        XCTAssertNotNil(buckets[0].queueWaitP95Ms)
        XCTAssertNotNil(buckets[0].executionP95Ms)

        XCTAssertEqual(buckets[1].requestCount, 1)
        XCTAssertEqual(buckets[1].requestP95Ms, 123)
        XCTAssertEqual(buckets[1].avgActiveRunners, 0)  // sampleCount == 0
        XCTAssertNil(buckets[1].avgRunnerUtilizationPercent)
        XCTAssertNil(buckets[1].queueWaitP95Ms)
    }

    // MARK: - percentile / average / percentile95

    func testPercentile95ReturnsNilForEmptyInput() {
        XCTAssertNil(MetricBucketAccumulators.percentile95([]))
    }

    func testPercentile95UsesNearestRankOnSortedCopy() {
        // values sorted: [10, 20, 30, 40, 50] -> idx = floor(4 * 0.95) = 3 -> value 40
        XCTAssertEqual(MetricBucketAccumulators.percentile95([30, 50, 10, 40, 20]), 40)
    }

    func testAverageReturnsIntegerMeanOrNil() {
        XCTAssertNil(MetricBucketAccumulators.average([]))
        XCTAssertEqual(MetricBucketAccumulators.average([10, 20, 30]), 20)
        XCTAssertEqual(MetricBucketAccumulators.average([1, 2]), 1)  // integer division
    }

    // MARK: - End-to-end pinned scenario

    func testEndToEndScenarioPinsBucketContents() {
        let resolved = BucketWindow.resolve(hours: 1, bucketMinutes: 30, defaultHours: 24, now: now)
        let window = resolved.window
        let bucket0Start = window.windowStart
        let bucket1Start = window.windowStart.addingTimeInterval(30 * 60)

        let snapshots = [
            RunnerSnapshot(
                runnerID: "r1",
                recordedAt: bucket0Start.addingTimeInterval(60),
                activeJobs: 2, maxJobs: 4, availableCapacity: 2,
                hostname: nil, runnerVersion: nil,
                lastPollAt: nil, lastHeartbeatAt: nil,
                serverAssignedJobCountSinceStart: nil
            ),
            RunnerSnapshot(
                runnerID: "r2",
                recordedAt: bucket1Start.addingTimeInterval(60),
                activeJobs: 1, maxJobs: 2, availableCapacity: 1,
                hostname: nil, runnerVersion: nil,
                lastPollAt: nil, lastHeartbeatAt: nil,
                serverAssignedJobCountSinceStart: nil
            ),
        ]
        let requests = [
            makeRequestMetric(at: bucket0Start, durationMs: 100),
            makeRequestMetric(at: bucket1Start.addingTimeInterval(120), durationMs: 800),
        ]
        let jobs = [
            makeJobMetric(
                completedAt: bucket0Start.addingTimeInterval(60),
                status: JobFinalStatus.passed.rawValue,
                queueWaitMs: 500,
                executionMs: 2_000
            ),
            makeJobMetric(
                completedAt: bucket1Start.addingTimeInterval(60),
                status: JobFinalStatus.timeout.rawValue
            ),
        ]

        let runnerBuckets = MetricBucketAccumulators.accumulateRunnerSnapshots(snapshots, window: window)
        let requestBuckets = MetricBucketAccumulators.accumulateRequestMetrics(requests, window: window)
        let jobBuckets = MetricBucketAccumulators.accumulateJobMetrics(jobs, window: window)
        let response = MetricBucketAccumulators.buildBucketResponses(
            window: window,
            runners: runnerBuckets,
            requests: requestBuckets,
            jobs: jobBuckets
        )

        XCTAssertEqual(response.count, 2)
        XCTAssertEqual(response[0].avgActiveRunners, 1)  // 1 sample, total 1
        XCTAssertEqual(response[0].avgRunnerUtilizationPercent, 50)
        XCTAssertEqual(response[0].requestCount, 1)
        XCTAssertEqual(response[0].requestP95Ms, 100)
        XCTAssertEqual(response[0].completedJobs, 1)
        XCTAssertEqual(response[0].passedCount, 1)
        XCTAssertEqual(response[0].queueWaitP95Ms, 500)
        XCTAssertEqual(response[0].executionP95Ms, 2_000)

        XCTAssertEqual(response[1].avgActiveRunners, 1)
        XCTAssertEqual(response[1].avgRunnerUtilizationPercent, 50)
        XCTAssertEqual(response[1].requestCount, 1)
        XCTAssertEqual(response[1].requestP95Ms, 800)
        XCTAssertEqual(response[1].completedJobs, 1)
        XCTAssertEqual(response[1].timeoutCount, 1)
        XCTAssertNil(response[1].queueWaitP95Ms)
        XCTAssertNil(response[1].executionP95Ms)
    }

    // MARK: - Helpers

    private func makeRequestMetric(at finishedAt: Date, durationMs: Int) -> APIRequestMetric {
        APIRequestMetric(
            method: "GET",
            path: "/api/test",
            requestKind: nil,
            statusCode: 200,
            startedAt: finishedAt.addingTimeInterval(-Double(durationMs) / 1000),
            finishedAt: finishedAt,
            durationMs: durationMs,
            submissionID: nil,
            workerID: nil
        )
    }

    private func makeJobMetric(
        completedAt: Date?,
        status: String?,
        queueWaitMs: Int? = nil,
        executionMs: Int? = nil
    ) -> JobExecutionMetric {
        let metric = JobExecutionMetric(
            submissionID: "sub_\(UUID().uuidString)",
            jobID: "job_\(UUID().uuidString)",
            testSetupID: "setup_t",
            courseID: nil,
            assignmentID: nil,
            userID: nil,
            runnerID: nil,
            kind: "student",
            attemptNumber: 1,
            enqueuedAt: nil
        )
        metric.completedAt = completedAt
        metric.finalStatus = status
        metric.queueWaitMs = queueWaitMs
        metric.executionMs = executionMs
        return metric
    }
}
