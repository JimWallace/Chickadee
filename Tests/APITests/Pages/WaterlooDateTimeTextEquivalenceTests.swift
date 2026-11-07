// Tests/APITests/Pages/WaterlooDateTimeTextEquivalenceTests.swift
//
// `waterlooDateTimeText(_:)` formats one date with a value-type
// `Date.FormatStyle` where a page used to build a `DateFormatter` (about
// 270 µs) for it, once per leaderboard row among them. These tests pin it to
// the bytes `waterlooDateTimeFormatter()` prints: the U+202F before AM or PM,
// Waterloo's daylight-saving changes, instants a fraction of a millisecond
// before a minute (the formatter rounds to the millisecond first), BC years,
// non-finite instants, and a seeded sweep over years 1 through 9999.

import Foundation
import Testing

@testable import APIServer

@Suite struct WaterlooDateTimeTextEquivalenceTests {

    /// SplitMix64, so the sweep visits the same instants on every run.
    private struct SeededGenerator: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    @Test(arguments: [
        0, 1_791_000_000, 1_791_000_059.9996, 1_791_000_059.9994, 1_791_000_060.0004, -0.0004,
        -0.0006, -86_400.25, -12_219_292_800, -62_135_769_600, -62_135_769_601, -70_000_000_000,
        253_402_300_799.9996, 253_402_300_800, 1e12,
    ])
    func edgeInstantsFormatLikeTheFormatter(secondsSince1970: Double) {
        let date = Date(timeIntervalSince1970: secondsSince1970)
        #expect(waterlooDateTimeText(date) == waterlooDateTimeFormatter().string(from: date))
    }

    @Test func distantAndNonFiniteInstantsFormatLikeTheFormatter() {
        let formatter = waterlooDateTimeFormatter()
        for date in [
            Date.distantPast, Date.distantFuture, Date(timeIntervalSince1970: .nan),
            Date(timeIntervalSince1970: .infinity),
        ] {
            #expect(waterlooDateTimeText(date) == formatter.string(from: date))
        }
    }

    @Test func waterlooDaylightSavingChangesFormatLikeTheFormatter() throws {
        let formatter = waterlooDateTimeFormatter()
        let toronto = try #require(TimeZone(identifier: "America/Toronto"))
        var cursor = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01
        let end = Date(timeIntervalSince1970: 1_893_456_000)  // 2030-01-01
        var changes = 0
        while let change = toronto.nextDaylightSavingTimeTransition(after: cursor), change < end {
            changes += 1
            for offset in stride(from: -7_200.0, through: 7_200, by: 60) {
                for fraction in [0, -0.0004, -0.0006] {
                    let date = change.addingTimeInterval(offset + fraction)
                    #expect(waterlooDateTimeText(date) == formatter.string(from: date))
                }
            }
            cursor = change
        }
        #expect(changes == 20)
    }

    @Test func seededSweepFormatsLikeTheFormatter() {
        let formatter = waterlooDateTimeFormatter()
        var generator = SeededGenerator(state: 1_118)
        var mismatches: [Double] = []
        for index in 0..<30_000 {
            let seconds: Double
            switch index % 3 {
            case 0:
                seconds = Double.random(in: -62_135_769_600..<253_402_300_800, using: &generator)
            case 1:
                seconds = Double.random(in: 1_500_000_000..<2_100_000_000, using: &generator)
            default:
                // Just before a minute, where the millisecond rounding shows.
                let minute = Double(Int64.random(in: 25_000_000..<35_000_000, using: &generator) * 60)
                seconds = minute - Double.random(in: 0.0001..<0.001, using: &generator)
            }
            let date = Date(timeIntervalSince1970: seconds)
            if waterlooDateTimeText(date) != formatter.string(from: date) {
                mismatches.append(seconds)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(5))")
    }
}
