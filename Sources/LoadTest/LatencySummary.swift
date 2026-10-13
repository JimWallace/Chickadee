// LoadTest/LatencySummary.swift
//
// The result for one scenario: counts by outcome and exact percentiles of
// the measured durations.

struct LatencySummary: Sendable, Equatable {
    let requestCount: Int
    /// Responses by HTTP status code.
    let statusCounts: [Int: Int]
    /// Requests that got no HTTP response (refused, reset, timed out).
    let transportErrors: Int
    let p50Ms: Double?
    let p95Ms: Double?
    let p99Ms: Double?
    let maxMs: Double?

    init(durationsMs: [Double], statusCounts: [Int: Int], transportErrors: Int) {
        let sorted = durationsMs.sorted()
        self.requestCount = sorted.count
        self.statusCounts = statusCounts
        self.transportErrors = transportErrors
        self.p50Ms = Self.percentile(sorted, 0.50)
        self.p95Ms = Self.percentile(sorted, 0.95)
        self.p99Ms = Self.percentile(sorted, 0.99)
        self.maxMs = sorted.last
    }

    /// Nearest rank: the value at rank `ceil(n × fraction)`, 1-based.
    static func percentile(_ sorted: [Double], _ fraction: Double) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let rank = max(1, Int((Double(sorted.count) * fraction).rounded(.up)))
        return sorted[min(rank, sorted.count) - 1]
    }
}
