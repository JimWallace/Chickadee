// LoadTest/LectureSchedule.swift
//
// When each simulated student joins and submits: the lecture's timeline in
// seconds from the start of the run.

struct LectureSchedule: Sendable, Equatable {
    /// Students start their join spread over this many seconds.
    let joinWindow: Double
    /// Seconds from the start until the first student submits.
    let workSeconds: Double
    /// Students submit spread over this many seconds.
    let submitWindow: Double
    /// Seconds the board is watched after the last submit.
    let watchSeconds: Double

    var totalSeconds: Double { workSeconds + submitWindow + watchSeconds }

    /// When student `index` of `count` joins, in seconds from the start.
    func joinOffset(index: Int, count: Int) -> Double {
        joinWindow * Double(index) / Double(max(1, count))
    }

    /// When student `index` of `count` submits, in seconds from the start.
    func submitOffset(index: Int, count: Int) -> Double {
        workSeconds + submitWindow * Double(index) / Double(max(1, count))
    }
}
