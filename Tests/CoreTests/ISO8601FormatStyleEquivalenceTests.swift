// Tests/CoreTests/ISO8601FormatStyleEquivalenceTests.swift
//
// `iso8601String` formats with the value-type `Date.ISO8601FormatStyle`
// instead of building an `ISO8601DateFormatter` per call. Every stored
// timestamp, ETag input and log line depends on the text being the same, so
// these tests pin it byte for byte against a freshly built legacy formatter:
// the edge instants (epoch, sub-second instants either side of the
// millisecond rounding the legacy formatter does, BC years, the distant past
// and future, non-finite instants), every Toronto daylight-saving change of a
// decade, and a seeded sweep over years 1 through 9999. The parse side is
// unchanged; the tests pin that it reads back what the format side writes and
// accepts and rejects what the legacy parser does.

import Foundation
import Testing

@testable import Core

@Suite struct ISO8601FormatStyleEquivalenceTests {

    /// The formatter `iso8601String` replaced, built once per test.
    private static func legacyFormatter() -> ISO8601DateFormatter {
        ISO8601DateFormatter()
    }

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

    /// Seconds since 1970 for 0001-01-01T00:00:00Z and 10000-01-01T00:00:00Z.
    private static let firstSecondOfYearOne = -62_135_769_600.0
    private static let firstSecondOfYear10000 = 253_402_300_800.0

    @Test(arguments: [
        0, 0.5, 0.999, 0.9994999, 0.9995, 0.9999999, -0.0001, -0.0005, -0.0006, -0.5, -1,
        1_791_000_000, 1_791_000_000.9999, 1_791_000_059.9996, -86_400.25,
        // The Julian-Gregorian change, and the first second of year 1.
        -12_219_292_800, -12_219_292_801, -62_135_596_800, -62_135_769_600, -62_135_769_600.0004,
        // BC years, which the legacy formatter prints as a year of era.
        -62_135_769_601, -62_167_219_200, -62_198_755_200, -70_000_000_000,
        // The last second of year 9999, and instants after it.
        253_402_300_799, 253_402_300_799.9994, 253_402_300_799.9996, 253_402_300_800,
        1e12, -1e12,
    ])
    func edgeInstantsFormatLikeTheLegacyFormatter(secondsSince1970: Double) {
        let date = Date(timeIntervalSince1970: secondsSince1970)
        #expect(iso8601String(date) == Self.legacyFormatter().string(from: date))
    }

    @Test func distantAndNonFiniteInstantsFormatLikeTheLegacyFormatter() {
        let legacy = Self.legacyFormatter()
        for date in [
            Date.distantPast, Date.distantFuture, Date(timeIntervalSinceReferenceDate: 0),
            Date(timeIntervalSince1970: .nan), Date(timeIntervalSince1970: .infinity),
            Date(timeIntervalSince1970: -.infinity),
        ] {
            #expect(iso8601String(date) == legacy.string(from: date), "\(date.timeIntervalSince1970)")
        }
    }

    @Test func torontoDaylightSavingChangesFormatLikeTheLegacyFormatter() throws {
        let legacy = Self.legacyFormatter()
        let toronto = try #require(TimeZone(identifier: "America/Toronto"))
        var cursor = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01
        let end = Date(timeIntervalSince1970: 1_893_456_000)  // 2030-01-01
        var changes = 0
        while let change = toronto.nextDaylightSavingTimeTransition(after: cursor), change < end {
            changes += 1
            for offset in stride(from: -3_600.0, through: 3_600, by: 900) {
                for fraction in [0, -0.0004, -0.0006, 0.5] {
                    let date = change.addingTimeInterval(offset + fraction)
                    #expect(iso8601String(date) == legacy.string(from: date))
                }
            }
            cursor = change
        }
        #expect(changes == 20)
    }

    @Test func seededSweepOverYearsOneThroughNineThousandFormatsLikeTheLegacyFormatter() {
        let legacy = Self.legacyFormatter()
        var generator = SeededGenerator(state: 2_492)
        var mismatches: [Double] = []
        for index in 0..<40_000 {
            let seconds: Double
            switch index % 3 {
            case 0:
                // Anywhere in years 1 through 9999.
                seconds = Double.random(
                    in: Self.firstSecondOfYearOne..<Self.firstSecondOfYear10000, using: &generator)
            case 1:
                // This century, where nearly every real timestamp is.
                seconds = Double.random(in: 1_500_000_000..<2_100_000_000, using: &generator)
            default:
                // A whole second plus a fraction near the millisecond rounding.
                let whole = Double(Int64.random(in: 1_500_000_000..<2_100_000_000, using: &generator))
                seconds = whole + Double.random(in: 0.9994..<0.9996, using: &generator)
            }
            let date = Date(timeIntervalSince1970: seconds)
            if iso8601String(date) != legacy.string(from: date) {
                mismatches.append(seconds)
            }
        }
        #expect(mismatches.isEmpty, "first mismatches: \(mismatches.prefix(5))")
    }

    @Test func formattedTextParsesBackToTheWholeSecondTheLegacyFormatterPrints() throws {
        let legacy = Self.legacyFormatter()
        for seconds in [0, 0.5, 0.9996, 1_791_000_000.25, -86_400.75, 253_402_300_799] {
            let date = Date(timeIntervalSince1970: seconds)
            let text = iso8601String(date)
            let parsed = try #require(iso8601Date(text))
            #expect(parsed == legacy.date(from: legacy.string(from: date)))
            #expect(iso8601String(parsed) == text)
        }
    }

    @Test(arguments: [
        "2026-10-08T21:30:00Z", "2026-10-08T21:30:00+05:00", "2026-10-08T21:30:00-0400",
        "2026-10-08T21:30:00.123Z", "2026-10-08T21:30:00", "2026-10-08", "21:30:00Z",
        "2026-10-08 21:30:00Z", "2026-13-01T00:00:00Z", "2026-02-30T00:00:00Z",
        "20261008T213000Z", "0001-01-01T00:00:00Z", "10000-01-01T00:00:00Z", "", "not a date",
    ])
    func parseAcceptsAndRejectsWhatTheLegacyParserDoes(text: String) {
        #expect(iso8601Date(text) == Self.legacyFormatter().date(from: text))
    }

    @Test func liveSessionWindowFormatsLikeItsInternetDateTimeFormatter() {
        let legacy = ISO8601DateFormatter()
        legacy.formatOptions = [.withInternetDateTime]
        for seconds in [0, 0.9996, 1_791_000_000.5, -1, 253_402_300_799.9996] {
            let date = Date(timeIntervalSince1970: seconds)
            #expect(LiveSessionWindow.format(date) == legacy.string(from: date))
        }
    }
}
