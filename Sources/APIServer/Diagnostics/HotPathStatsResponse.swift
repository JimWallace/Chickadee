import Vapor

/// The `hotPaths` part of `/admin/metrics` and `get_metrics_snapshot`.
struct HotPathStatsResponse: Content, Sendable {
    /// When this process started to count. The counts are per process.
    let countingSince: Date
    let windowMinutes: Int
    let routes: [HotPathRouteStatsResponse]
}

struct HotPathRouteStatsResponse: Content, Sendable {
    let route: String
    let sinceStart: HotPathLatencySummaryResponse
    /// The last `windowMinutes` minutes, including the current minute.
    let lastWindow: HotPathLatencySummaryResponse
    let peakRequestsPerMinute: Int
}

struct HotPathLatencySummaryResponse: Content, Sendable {
    let requestCount: Int
    /// Responses with a status of 400 or more.
    let errorCount: Int
    /// Bucket upper bounds; see `LatencyHistogram.percentileMs`.
    let p50Ms: Int?
    let p95Ms: Int?
    let p99Ms: Int?
    let maxMs: Int?

    init(_ histogram: LatencyHistogram) {
        requestCount = histogram.requestCount
        errorCount = histogram.errorCount
        p50Ms = histogram.percentileMs(0.50)
        p95Ms = histogram.percentileMs(0.95)
        p99Ms = histogram.percentileMs(0.99)
        maxMs = histogram.maxMs
    }
}
