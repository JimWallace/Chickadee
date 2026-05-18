import Foundation
import Testing

@testable import chickadee_server

@Suite struct MetricBucketAccumulatorsTests {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - BucketWindow.resolve

    @Test func resolveClampsHoursToOneToSeventyTwoRange() {
        let low = BucketWindow.resolve(hours: 0, bucketMinutes: 15, defaultHours: 24, now: now)
        #expect(low.hours == 1)

        let high = BucketWindow.resolve(hours: 200, bucketMinutes: 15, defaultHours: 24, now: now)
        #expect(high.hours == 72)
    }

    @Test func resolveClampsBucketMinutesToOneToSixtyRange() {
        let low = BucketWindow.resolve(hours: 1, bucketMinutes: 0, defaultHours: 24, now: now)
        #expect(low.bucketMinutes == 1)
        #expect(low.window.bucketSeconds == 60)

        let high = BucketWindow.resolve(hours: 1, bucketMinutes: 600, defaultHours: 24, now: now)
        #expect(high.bucketMinutes == 60)
        #expect(high.window.bucketSeconds == 3600)
    }

    @Test func resolveFallsBackToDefaultsWhenNothingProvided() {
        let resolved = BucketWindow.resolve(hours: nil, bucketMinutes: nil, defaultHours: 6, now: now)
        #expect(resolved.hours == 6)
        #expect(resolved.bucketMinutes == 15)
        #expect(resolved.window.bucketSeconds == 900)
        #expect(resolved.window.bucketCount == (6 * 3600) / 900)
        #expect(resolved.window.windowStart == now.addingTimeInterval(-6 * 3600))
    }

    @Test func resolveBucketCountRoundsUpWhenWindowIsNotEvenlyDivisible() {
        // 1h with 17-minute buckets -> ceil(3600 / 1020) = 4 buckets
        let resolved = BucketWindow.resolve(hours: 1, bucketMinutes: 17, defaultHours: 24, now: now)
        #expect(resolved.window.bucketCount == 4)
    }

    // MARK: - bucketIndex

    @Test func bucketIndexReturnsNilForDateBeforeWindowStart() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 15, defaultHours: 24, now: now).window
        #expect(window.bucketIndex(for: window.windowStart.addingTimeInterval(-1)) == nil)
    }

    @Test func bucketIndexReturnsNilForDateAtOrBeyondWindowEnd() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 15, defaultHours: 24, now: now).window
        let windowEnd = window.windowStart.addingTimeInterval(Double(window.bucketSeconds * window.bucketCount))
        #expect(window.bucketIndex(for: windowEnd) == nil)
        #expect(window.bucketIndex(for: windowEnd.addingTimeInterval(60)) == nil)
    }

    @Test func bucketIndexReturnsCorrectIndexForDatesInsideWindow() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 15, defaultHours: 24, now: now).window

        #expect(window.bucketIndex(for: window.windowStart) == 0)
        #expect(window.bucketIndex(for: window.windowStart.addingTimeInterval(15 * 60 - 1)) == 0)
        #expect(window.bucketIndex(for: window.windowStart.addingTimeInterval(15 * 60)) == 1)
        #expect(window.bucketIndex(for: window.windowStart.addingTimeInterval(45 * 60)) == 3)
    }

    // MARK: - accumulateRunnerSnapshots

    @Test func accumulateRunnerSnapshotsSkipsOutOfRangeSamples() {
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

        #expect(buckets.count == window.bucketCount)
        #expect(buckets[0].sampleCount == 1)
        #expect(buckets[0].activeRunnerTotal == 1)
        #expect(buckets[0].utilizationValues == [25])
        #expect(buckets[1].sampleCount == 0)
    }

    @Test func accumulateRunnerSnapshotsClampsUtilizationToHundred() {
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

        #expect(buckets[0].utilizationValues == [100])
    }

    @Test func accumulateRunnerSnapshotsSkipsUtilizationWhenMaxJobsIsZero() {
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

        #expect(buckets[0].sampleCount == 1)
        #expect(buckets[0].activeRunnerTotal == 1)
        #expect(buckets[0].utilizationValues.isEmpty)
    }

    // MARK: - accumulateRequestMetrics

    @Test func accumulateRequestMetricsCollectsDurations() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 30, defaultHours: 24, now: now).window
        let bucket0 = makeRequestMetric(at: window.windowStart, durationMs: 50)
        let bucket0Again = makeRequestMetric(at: window.windowStart.addingTimeInterval(60), durationMs: 75)
        let bucket1 = makeRequestMetric(at: window.windowStart.addingTimeInterval(31 * 60), durationMs: 200)
        let outOfRange = makeRequestMetric(at: window.windowStart.addingTimeInterval(-5), durationMs: 999)

        let buckets = MetricBucketAccumulators.accumulateRequestMetrics(
            [bucket0, bucket0Again, bucket1, outOfRange],
            window: window
        )

        #expect(buckets[0].requestCount == 2)
        #expect(buckets[0].durationValues.sorted() == [50, 75])
        #expect(buckets[1].requestCount == 1)
        #expect(buckets[1].durationValues == [200])
    }

    // MARK: - accumulateJobMetrics

    @Test func accumulateJobMetricsRoutesEachStatusToTheCorrectCounter() {
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

        #expect(buckets[0].completedJobs == 6)
        #expect(buckets[0].passedCount == 1)
        #expect(buckets[0].failedCount == 1)
        #expect(buckets[0].errorCount == 1)
        #expect(buckets[0].timeoutCount == 1)
    }

    @Test func accumulateJobMetricsSkipsRowsWithoutCompletedAt() {
        let window = BucketWindow.resolve(hours: 1, bucketMinutes: 60, defaultHours: 24, now: now).window
        let metric = makeJobMetric(completedAt: nil, status: JobFinalStatus.passed.rawValue)

        let buckets = MetricBucketAccumulators.accumulateJobMetrics([metric], window: window)

        #expect(buckets[0].completedJobs == 0)
        #expect(buckets[0].passedCount == 0)
    }

    @Test func accumulateJobMetricsCollectsTimingValues() {
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

        #expect(buckets[0].queueWaitValues == [250])
        #expect(buckets[0].executionValues == [1_750])
    }

    // MARK: - buildBucketResponses

    @Test func buildBucketResponsesProducesExpectedBucketStartsAndAggregates() {
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

        #expect(buckets.count == window.bucketCount)
        #expect(buckets[0].bucketStart == window.windowStart)
        #expect(buckets[1].bucketStart == window.windowStart.addingTimeInterval(Double(window.bucketSeconds)))

        #expect(buckets[0].avgActiveRunners == 3)
        #expect(buckets[0].avgRunnerUtilizationPercent == 60)  // average(40, 60, 80) = 60
        #expect(buckets[0].maxRunnerUtilizationPercent == 80)
        #expect(buckets[0].completedJobs == 4)
        #expect(buckets[0].passedCount == 3)
        #expect(buckets[0].failedCount == 1)
        #expect(buckets[0].queueWaitP95Ms != nil)
        #expect(buckets[0].executionP95Ms != nil)

        #expect(buckets[1].requestCount == 1)
        #expect(buckets[1].requestP95Ms == 123)
        #expect(buckets[1].avgActiveRunners == 0)  // sampleCount == 0
        #expect(buckets[1].avgRunnerUtilizationPercent == nil)
        #expect(buckets[1].queueWaitP95Ms == nil)
    }

    // MARK: - percentile / average / percentile95

    @Test func percentile95ReturnsNilForEmptyInput() {
        #expect(MetricBucketAccumulators.percentile95([]) == nil)
    }

    @Test func percentile95UsesNearestRankOnSortedCopy() {
        // values sorted: [10, 20, 30, 40, 50] -> idx = floor(4 * 0.95) = 3 -> value 40
        #expect(MetricBucketAccumulators.percentile95([30, 50, 10, 40, 20]) == 40)
    }

    @Test func averageReturnsIntegerMeanOrNil() {
        #expect(MetricBucketAccumulators.average([]) == nil)
        #expect(MetricBucketAccumulators.average([10, 20, 30]) == 20)
        #expect(MetricBucketAccumulators.average([1, 2]) == 1)  // integer division
    }

    // MARK: - End-to-end pinned scenario

    @Test func endToEndScenarioPinsBucketContents() {
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

        #expect(response.count == 2)
        #expect(response[0].avgActiveRunners == 1)  // 1 sample, total 1
        #expect(response[0].avgRunnerUtilizationPercent == 50)
        #expect(response[0].requestCount == 1)
        #expect(response[0].requestP95Ms == 100)
        #expect(response[0].completedJobs == 1)
        #expect(response[0].passedCount == 1)
        #expect(response[0].queueWaitP95Ms == 500)
        #expect(response[0].executionP95Ms == 2_000)

        #expect(response[1].avgActiveRunners == 1)
        #expect(response[1].avgRunnerUtilizationPercent == 50)
        #expect(response[1].requestCount == 1)
        #expect(response[1].requestP95Ms == 800)
        #expect(response[1].completedJobs == 1)
        #expect(response[1].timeoutCount == 1)
        #expect(response[1].queueWaitP95Ms == nil)
        #expect(response[1].executionP95Ms == nil)
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
