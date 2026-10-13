/// A fixed-bucket latency histogram. Its memory does not grow with the
/// number of requests, so it can count every request on a hot path.
///
/// A percentile is the upper bound of the bucket that holds it, capped at
/// the largest duration seen. It is an upper bound, not an exact value.
struct LatencyHistogram: Sendable, Equatable {
    /// Bucket upper bounds in milliseconds. One more bucket holds every
    /// duration above the last bound.
    static let bucketUpperBoundsMs = [1, 2, 5, 10, 25, 50, 100, 250, 500, 1_000, 2_500, 5_000, 10_000]

    private(set) var bucketCounts = [Int](repeating: 0, count: bucketUpperBoundsMs.count + 1)
    private(set) var requestCount = 0
    private(set) var errorCount = 0
    private(set) var maxMs: Int?

    mutating func record(durationMs: Int, isError: Bool) {
        let duration = max(0, durationMs)
        let index =
            Self.bucketUpperBoundsMs.firstIndex(where: { duration <= $0 })
            ?? Self.bucketUpperBoundsMs.count
        bucketCounts[index] += 1
        requestCount += 1
        if isError { errorCount += 1 }
        maxMs = max(maxMs ?? duration, duration)
    }

    mutating func merge(_ other: LatencyHistogram) {
        for index in bucketCounts.indices {
            bucketCounts[index] += other.bucketCounts[index]
        }
        requestCount += other.requestCount
        errorCount += other.errorCount
        if let otherMax = other.maxMs {
            maxMs = max(maxMs ?? otherMax, otherMax)
        }
    }

    /// The upper bound of the bucket that holds rank `ceil(requestCount × fraction)`,
    /// or nil when the histogram is empty.
    func percentileMs(_ fraction: Double) -> Int? {
        guard let maxMs else { return nil }
        let rank = max(1, Int((Double(requestCount) * fraction).rounded(.up)))
        var seen = 0
        for (index, bucketCount) in bucketCounts.enumerated() {
            seen += bucketCount
            guard seen >= rank else { continue }
            guard index < Self.bucketUpperBoundsMs.count else { return maxMs }
            return min(Self.bucketUpperBoundsMs[index], maxMs)
        }
        return maxMs
    }
}
