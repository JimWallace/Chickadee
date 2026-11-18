// Tests/APITests/Admin/RunnerFleetFormattingTests.swift
//
// `formatMs` and `formatBytes` write the durations and sizes on the runner
// fleet page. The fleet page tests reach only the short values. This suite
// pins each unit boundary, the hour forms of a duration (an hour drops its
// seconds) and the sizes from 100 MB up.

import Foundation
import Testing

@testable import APIServer

@Suite struct RunnerFleetFormattingTests {

    @Test(arguments: [
        (0, "0ms"),
        (999, "999ms"),
        (1_000, "1s"),
        (59_999, "59s"),
        (60_000, "1m"),
        (90_000, "1m 30s"),
        (3_599_000, "59m 59s"),
        (3_600_000, "1h"),
        (5_400_000, "1h 30m"),
        // At the hour scale the seconds are dropped.
        (5_430_000, "1h 30m"),
        (7_200_000, "2h"),
        (90_000_000, "25h"),
    ])
    func aDurationIsWrittenInItsLargestUnits(milliseconds: Int, expected: String) {
        #expect(formatMs(milliseconds) == expected)
    }

    @Test(arguments: [
        (0, "0 B"),
        (1_023, "1023 B"),
        (2_048, "2 KB"),
        (1_572_864, "1.5 MB"),
        // From 100 MB the decimal is dropped.
        (157_286_400, "150 MB"),
        (1_073_741_824, "1.0 GB"),
        (2_684_354_560, "2.5 GB"),
    ])
    func aSizeIsWrittenInItsLargestUnit(bytes: Int, expected: String) {
        #expect(formatBytes(bytes) == expected)
    }
}
