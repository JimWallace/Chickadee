// LoadTest/StreamRecorder.swift
//
// Collects every measured request from the concurrent clients, keyed by the
// stream it belongs to: a `LoadScenario` for the hot-path run, a
// `LectureStream` for the lecture run.

/// The hot-path run's recorder.
typealias LatencyRecorder = StreamRecorder<LoadScenario>

actor StreamRecorder<Stream: Hashable & Sendable> {
    private var durationsMs: [Stream: [Double]] = [:]
    private var statusCounts: [Stream: [Int: Int]] = [:]
    private var transportErrors: [Stream: Int] = [:]
    private var bytes: [Stream: Int] = [:]

    func record(_ stream: Stream, statusCode: Int, durationMs: Double, byteCount: Int = 0) {
        durationsMs[stream, default: []].append(durationMs)
        statusCounts[stream, default: [:]][statusCode, default: 0] += 1
        bytes[stream, default: 0] += byteCount
    }

    func recordTransportError(_ stream: Stream) {
        transportErrors[stream, default: 0] += 1
    }

    func summary(for stream: Stream) -> LatencySummary {
        LatencySummary(
            durationsMs: durationsMs[stream] ?? [],
            statusCounts: statusCounts[stream] ?? [:],
            transportErrors: transportErrors[stream] ?? 0
        )
    }

    /// The response bytes the stream received, summed.
    func byteCount(for stream: Stream) -> Int {
        bytes[stream] ?? 0
    }
}
