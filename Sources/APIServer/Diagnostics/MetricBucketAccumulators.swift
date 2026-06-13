import Foundation

/// Time-window descriptor used by the `/admin/metrics/timeseries` endpoint.
///
/// Captures the user-tunable window (hours / bucketMinutes) clamped to the
/// supported ranges and exposes a pure `bucketIndex(for:)` mapping. Resolved
/// up-front so all downstream accumulators share consistent bounds.
struct BucketWindow: Sendable, Equatable {
    let windowStart: Date
    let bucketSeconds: Int
    let bucketCount: Int

    /// Resolve user-supplied query parameters into a normalised window.
    ///
    /// `hours` is clamped to `[1, 72]`, `bucketMinutes` to `[1, 60]`, matching
    /// the original behaviour of `metricsTimeSeriesSnapshot`.
    static func resolve(
        hours requestedHours: Int?,
        bucketMinutes requestedBucketMinutes: Int?,
        defaultHours: Int,
        now: Date
    ) -> (window: BucketWindow, hours: Int, bucketMinutes: Int) {
        let hours = min(max(requestedHours ?? defaultHours, 1), 72)
        let bucketMinutes = min(max(requestedBucketMinutes ?? 15, 1), 60)
        let bucketSeconds = bucketMinutes * 60
        let bucketCount = max(1, Int(ceil(Double(hours * 3600) / Double(bucketSeconds))))
        let windowStart = now.addingTimeInterval(Double(-hours) * 3600)
        let window = BucketWindow(
            windowStart: windowStart,
            bucketSeconds: bucketSeconds,
            bucketCount: bucketCount
        )
        return (window, hours, bucketMinutes)
    }

    /// Map an arbitrary timestamp into a bucket index, or `nil` if the
    /// timestamp falls outside the configured window.
    func bucketIndex(for date: Date) -> Int? {
        let delta = Int(date.timeIntervalSince(windowStart))
        guard delta >= 0 else { return nil }
        let index = delta / bucketSeconds
        guard index >= 0, index < bucketCount else { return nil }
        return index
    }

    /// Start timestamp for the bucket at `index`.
    func bucketStart(forIndex index: Int) -> Date {
        windowStart.addingTimeInterval(Double(index * bucketSeconds))
    }
}

struct RunnerBucketAccumulator: Sendable, Equatable {
    var sampleCount = 0
    var activeRunnerTotal = 0
    var utilizationValues: [Int] = []
}

/// Per-bucket runner summary used to build the time-series response.  Decouples
/// the wire response from *how* the runner stats were aggregated: the SQLite /
/// test path summarizes raw `RunnerBucketAccumulator`s in Swift, while Postgres
/// computes these three values directly in the database (see
/// `runnerTimeseriesSummaries`).  Both paths must produce identical summaries.
struct RunnerBucketSummary: Sendable, Equatable {
    var avgUtilizationPercent: Int?
    var maxUtilizationPercent: Int?
    var avgActiveRunners: Int

    static let empty = RunnerBucketSummary(
        avgUtilizationPercent: nil, maxUtilizationPercent: nil, avgActiveRunners: 0)
}

struct RequestBucketAccumulator: Sendable, Equatable {
    var requestCount = 0
    var durationValues: [Int] = []
}

struct JobBucketAccumulator: Sendable, Equatable {
    var completedJobs = 0
    var passedCount = 0
    var failedCount = 0
    var errorCount = 0
    var timeoutCount = 0
    var queueWaitValues: [Int] = []
    var executionValues: [Int] = []
}

/// Pure aggregation helpers for the `/admin/metrics/timeseries` endpoint.
///
/// Each `accumulate*` function takes the raw model rows already loaded from
/// the database and returns one accumulator per bucket. `buildBucketResponses`
/// collapses three parallel accumulator arrays into the wire response. None of
/// these functions touch the database; they exist to make the bucket-window
/// math testable in isolation.
enum MetricBucketAccumulators {
    static func accumulateRunnerSnapshots(
        _ snapshots: [RunnerSnapshot],
        window: BucketWindow
    ) -> [RunnerBucketAccumulator] {
        var buckets = Array(repeating: RunnerBucketAccumulator(), count: window.bucketCount)
        for snapshot in snapshots {
            guard let index = window.bucketIndex(for: snapshot.recordedAt) else { continue }
            buckets[index].sampleCount += 1
            buckets[index].activeRunnerTotal += 1
            if snapshot.maxJobs > 0 {
                let utilization = Int((Double(snapshot.activeJobs) / Double(snapshot.maxJobs) * 100).rounded())
                buckets[index].utilizationValues.append(min(100, max(0, utilization)))
            }
        }
        return buckets
    }

    static func accumulateRequestMetrics(
        _ metrics: [APIRequestMetric],
        window: BucketWindow
    ) -> [RequestBucketAccumulator] {
        var buckets = Array(repeating: RequestBucketAccumulator(), count: window.bucketCount)
        for metric in metrics {
            guard let index = window.bucketIndex(for: metric.finishedAt) else { continue }
            buckets[index].requestCount += 1
            buckets[index].durationValues.append(metric.durationMs)
        }
        return buckets
    }

    static func accumulateJobMetrics(
        _ metrics: [JobExecutionMetric],
        window: BucketWindow
    ) -> [JobBucketAccumulator] {
        var buckets = Array(repeating: JobBucketAccumulator(), count: window.bucketCount)
        for metric in metrics {
            guard let completedAt = metric.completedAt,
                let index = window.bucketIndex(for: completedAt)
            else { continue }

            buckets[index].completedJobs += 1
            if let queueWaitMs = metric.queueWaitMs {
                buckets[index].queueWaitValues.append(queueWaitMs)
            }
            if let executionMs = metric.executionMs {
                buckets[index].executionValues.append(executionMs)
            }

            switch metric.finalStatus {
            case JobFinalStatus.passed.rawValue:
                buckets[index].passedCount += 1
            case JobFinalStatus.failed.rawValue:
                buckets[index].failedCount += 1
            case JobFinalStatus.error.rawValue:
                buckets[index].errorCount += 1
            case JobFinalStatus.timeout.rawValue:
                buckets[index].timeoutCount += 1
            default:
                break
            }
        }
        return buckets
    }

    /// Collapse raw per-bucket accumulators into the lighter per-bucket
    /// summaries the response is built from.  Used by the SQLite / test path;
    /// the Postgres path computes equivalent summaries directly in SQL.
    static func summarizeRunnerBuckets(
        _ accumulators: [RunnerBucketAccumulator]
    ) -> [RunnerBucketSummary] {
        accumulators.map { runner in
            let avgActiveRunners =
                runner.sampleCount > 0
                ? Int((Double(runner.activeRunnerTotal) / Double(runner.sampleCount)).rounded())
                : 0
            return RunnerBucketSummary(
                avgUtilizationPercent: average(runner.utilizationValues),
                maxUtilizationPercent: runner.utilizationValues.max(),
                avgActiveRunners: avgActiveRunners
            )
        }
    }

    static func buildBucketResponses(
        window: BucketWindow,
        runners: [RunnerBucketSummary],
        requests: [RequestBucketAccumulator],
        jobs: [JobBucketAccumulator]
    ) -> [InternalMetricsBucketResponse] {
        (0..<window.bucketCount).map { index in
            let runner = runners[index]
            let request = requests[index]
            let job = jobs[index]
            return InternalMetricsBucketResponse(
                bucketStart: window.bucketStart(forIndex: index),
                avgRunnerUtilizationPercent: runner.avgUtilizationPercent,
                maxRunnerUtilizationPercent: runner.maxUtilizationPercent,
                avgActiveRunners: runner.avgActiveRunners,
                requestCount: request.requestCount,
                requestP95Ms: percentile95(request.durationValues),
                completedJobs: job.completedJobs,
                passedCount: job.passedCount,
                failedCount: job.failedCount,
                errorCount: job.errorCount,
                timeoutCount: job.timeoutCount,
                queueWaitP95Ms: percentile95(job.queueWaitValues),
                executionP95Ms: percentile95(job.executionValues)
            )
        }
    }

    static func percentile(_ sortedValues: [Int], percentile: Double) -> Int? {
        guard !sortedValues.isEmpty else { return nil }
        let index = min(sortedValues.count - 1, max(0, Int(Double(sortedValues.count - 1) * percentile)))
        return sortedValues[index]
    }

    static func average(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / values.count
    }

    static func percentile95(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        return percentile(values.sorted(), percentile: 0.95)
    }
}
