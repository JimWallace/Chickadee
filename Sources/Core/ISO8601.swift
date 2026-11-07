// Core/ISO8601.swift
//
// The one spelling of an ISO 8601 date-time (#2492): internet date-time, in
// UTC, with no fractional seconds — the default `ISO8601DateFormatter`. The
// code used to construct that formatter inline in some fifty places.
//
// Formatting goes through the value-type `Date.ISO8601FormatStyle`: building an
// `ISO8601DateFormatter` opens an ICU formatter (about 85 µs on Linux), and
// some callers format one date per roster row or per runner log line. The
// output is byte-identical to the legacy formatter's, which
// `ISO8601FormatStyleEquivalenceTests` pins.

public import Foundation

/// The style `iso8601String` formats with. Its defaults are the legacy
/// formatter's `.withInternetDateTime`: UTC, dashes, colons, a "T" and a "Z".
private let iso8601Style = Date.ISO8601FormatStyle()

/// Formats `date` as an ISO 8601 date-time, such as "2026-10-08T21:30:00Z".
public func iso8601String(_ date: Date) -> String {
    // Outside years 1 through 9999 the two disagree (the legacy formatter
    // prints a BC year as its year of era), so the legacy one answers there.
    guard let second = date.legacyFormatterWholeSecond else {
        return ISO8601DateFormatter().string(from: date)
    }
    return iso8601Style.format(second)
}

/// Parses an ISO 8601 date-time in the form `iso8601String` writes, or returns
/// nil.
public func iso8601Date(_ string: String) -> Date? {
    ISO8601DateFormatter().date(from: string)
}

extension Date {
    /// This instant cut to the whole second that an ICU-backed `DateFormatter`
    /// or `ISO8601DateFormatter` prints for it, or nil outside years 1
    /// through 9999 and for a non-finite instant.
    ///
    /// CoreFoundation hands ICU `(t + 978307200) * 1000 + 0.5` milliseconds,
    /// so the legacy formatters round to the nearest millisecond before they
    /// drop the fraction: 21:30:00.9996 prints as 21:30:01. A value-type
    /// `FormatStyle` floors the raw instant, so about one instant in 2000
    /// would print a second (or, at minute precision, a minute) earlier.
    /// Formatting the whole second this returns makes a style print what the
    /// legacy formatter prints. The year range is where the two were compared
    /// (`ISO8601FormatStyleEquivalenceTests`); outside it, format with the
    /// legacy formatter.
    public var legacyFormatterWholeSecond: Date? {
        let icuMilliseconds = (timeIntervalSinceReferenceDate + 978_307_200) * 1000 + 0.5
        let seconds = (icuMilliseconds.rounded(.down) / 1000).rounded(.down)
        // 0001-01-01T00:00:00Z (`Date.distantPast`) up to 10000-01-01T00:00:00Z.
        // A NaN fails both comparisons.
        guard seconds >= -62_135_769_600, seconds < 253_402_300_800 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }
}
