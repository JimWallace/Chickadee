// Sources/APIServer/Diagnostics/QueueDepthLogSampleStore.swift

/// Lets the `queue_depth` field of the `job_enqueued` and `job_assigned` log
/// lines reuse a recent count while the pending backlog is large.
///
/// The field is filled on every claim and every accepted submission, and the
/// count behind it (`pendingQueueDepth(on:)`) reads every pending row. At a
/// 25,000-row backlog that was 7 to 10 ms per event, and the claim response
/// waited for it. While the last count read at least `minimumCountedRows`
/// rows, a count started less than `reuseWindow` ago is logged again, so the
/// claims of one window share one count. The check and the store are separate
/// steps, so when a window ends, the events that arrive together each count
/// once before the first of them stores its result; that is never more
/// counting than before. A smaller count costs under a millisecond and clears the
/// sample, so below that size every log line carries an exact count, as
/// before.
///
/// Only the log field reads through this store. `GetQueueStateTool` calls
/// `pendingQueueDepth(on:)` itself and stays exact.
actor QueueDepthLogSampleStore {
    /// How long a large count stays reusable. In that time the depth moves
    /// only by the claims and submissions of those seconds, a small share of
    /// a backlog this large; a retest fan-out or a bulk reset shows in the
    /// log within this window.
    static let reuseWindow: Duration = .seconds(5)

    /// The rows a count must read before it is worth reusing. Below this the
    /// grouped count measured 0.3 to 0.7 ms, most of it planning.
    static let minimumCountedRows = 1_000

    private struct Sample {
        let depth: Int
        let takenAt: ContinuousClock.Instant
    }

    private var sample: Sample?

    /// The depth to log at `now`, or nil when the caller must count.
    func reusableDepth(at now: ContinuousClock.Instant) -> Int? {
        guard let sample, now < sample.takenAt + Self.reuseWindow else { return nil }
        return sample.depth
    }

    /// Records a count that started at `takenAt` and read `countedRows`
    /// rows. A count that started before the stored one is dropped, so two
    /// overlapping counts never replace a newer value with an older one.
    func record(depth: Int, countedRows: Int, takenAt: ContinuousClock.Instant) {
        if let sample, sample.takenAt > takenAt { return }
        sample = countedRows >= Self.minimumCountedRows ? Sample(depth: depth, takenAt: takenAt) : nil
    }
}
