import Testing

@testable import APIServer

/// The `queue_depth` log field reuses a count only while the backlog is
/// large, and only for a few seconds. These pin both limits, so a drained
/// queue is logged exactly again from the next event on.
@Suite struct QueueDepthLogSampleStoreTests {
    private let large = QueueDepthLogSampleStore.minimumCountedRows
    private let window = QueueDepthLogSampleStore.reuseWindow

    @Test func anEmptyStoreHasNothingToReuse() async {
        let store = QueueDepthLogSampleStore()
        #expect(await store.reusableDepth(at: .now) == nil)
    }

    @Test func aLargeCountIsReusedUntilTheWindowEnds() async {
        let store = QueueDepthLogSampleStore()
        let start = ContinuousClock.now
        await store.record(depth: 24_990, countedRows: large, takenAt: start)

        #expect(await store.reusableDepth(at: start) == 24_990)
        #expect(await store.reusableDepth(at: start + window - .milliseconds(1)) == 24_990)
        #expect(await store.reusableDepth(at: start + window) == nil)
    }

    @Test func aSmallCountIsNeverReused() async {
        let store = QueueDepthLogSampleStore()
        let start = ContinuousClock.now
        await store.record(depth: 12, countedRows: large - 1, takenAt: start)

        #expect(await store.reusableDepth(at: start) == nil)
    }

    /// The backlog drained: the next count is small, and from then on every
    /// event counts again, however recent the large count was.
    @Test func aSmallCountClearsALargeOne() async {
        let store = QueueDepthLogSampleStore()
        let start = ContinuousClock.now
        await store.record(depth: 24_990, countedRows: large, takenAt: start)
        await store.record(depth: 3, countedRows: 3, takenAt: start + .milliseconds(10))

        #expect(await store.reusableDepth(at: start + .milliseconds(20)) == nil)
    }

    /// Two counts that overlap can finish in either order. The one that
    /// started later saw the newer queue, so the earlier one never replaces
    /// or clears it.
    @Test func anOlderCountNeverReplacesANewerOne() async {
        let store = QueueDepthLogSampleStore()
        let start = ContinuousClock.now
        await store.record(depth: 25_000, countedRows: large, takenAt: start + .milliseconds(10))
        await store.record(depth: 30_000, countedRows: large, takenAt: start)
        await store.record(depth: 3, countedRows: 3, takenAt: start)

        #expect(await store.reusableDepth(at: start + .milliseconds(20)) == 25_000)
    }
}
