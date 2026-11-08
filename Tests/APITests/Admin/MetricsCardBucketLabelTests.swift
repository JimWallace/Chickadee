// Tests/APITests/Admin/MetricsCardBucketLabelTests.swift
//
// `MetricsCardWindow.bucketLabels(for:)` labels every bucket from one shared
// formatter instead of building a `DateFormatter` per label. These tests pin
// that the strings are the same as the per-label form, including across both
// America/Toronto daylight-saving changes.

import Foundation
import Testing

@testable import APIServer

@Suite struct MetricsCardBucketLabelTests {
    /// Instants on each side of the 2026 America/Toronto DST changes
    /// (2026-03-08 and 2026-11-01), so some grids span a change.
    static let nows = [
        "2026-03-07T12:00:00Z",
        "2026-03-08T12:00:00Z",
        "2026-03-09T12:00:00Z",
        "2026-10-31T12:00:00Z",
        "2026-11-01T12:00:00Z",
        "2026-11-02T12:00:00Z",
    ]

    /// The label as the per-bucket implementation built it before the shared
    /// formatter: a fresh, identically configured formatter for every label.
    private static func referenceLabel(_ window: MetricsCardWindow, _ start: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_CA")
        fmt.timeZone = TimeZone(identifier: "America/Toronto")
        switch window {
        case .day: fmt.dateFormat = "HH:mm"
        case .week: fmt.dateFormat = "EEE HH:mm"
        case .month: fmt.dateFormat = "MMM d"
        }
        return fmt.string(from: start)
    }

    @Test(arguments: MetricsCardWindow.allCases, nows)
    func sharedFormatterMatchesPerLabelFormatter(window: MetricsCardWindow, iso: String) throws {
        let now = try Date(iso, strategy: .iso8601)
        let grid = window.bucketWindow(endingAt: now)
        let starts = (0..<grid.bucketCount).map { grid.bucketStart(forIndex: $0) }
        let labels = window.bucketLabels(for: grid)
        #expect(labels.count == window.bucketCount)
        #expect(labels == starts.map { window.label(forBucketStart: $0) })
        #expect(labels == starts.map { Self.referenceLabel(window, $0) })
    }
}
