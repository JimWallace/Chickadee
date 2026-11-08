// APIServer/Utilities/WaterlooDateTimeFormatter.swift
//
// The one display formatter for a timestamp shown to a person: Canadian
// English, Waterloo local time, medium date and short time. Every page that
// prints a date calls it, so the five-drifted-display-sites bug class (#1118)
// cannot return. Lived in Routes/Web/AssignmentHelpers.swift until #2143;
// the course timeline and the BrightSpace presenter call it from below the
// routes.
//
// Two spellings of the same text. `waterlooDateTimeFormatter()` builds a
// `DateFormatter` (about 270 µs on Linux, most of it the ICU set-up), for a
// builder that formats many dates and passes the formatter down.
// `waterlooDateTimeText(_:)` formats one date with a value-type style and
// builds nothing, for a site that formats one date, or one per row.
// `WaterlooDateTimeTextEquivalenceTests` pins the two to the same bytes.

import Core
import Foundation

func waterlooDateTimeFormatter() -> DateFormatter {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_CA")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateStyle = .medium
    fmt.timeStyle = .short
    return fmt
}

/// The style `waterlooDateTimeText` formats with: the formatter's medium date
/// and short time, as a value type. A nil zone falls back to the current one,
/// as the formatter's does.
private let waterlooDateTimeStyle = Date.FormatStyle(
    date: .abbreviated, time: .shortened, locale: Locale(identifier: "en_CA"),
    calendar: Calendar(identifier: .gregorian),
    timeZone: TimeZone(identifier: "America/Toronto") ?? .current)

/// `waterlooDateTimeFormatter().string(from: date)`, such as
/// "Sep 21, 2026 at 10:13 AM", without building a formatter.
func waterlooDateTimeText(_ date: Date) -> String {
    // The whole second the formatter prints, so an instant a fraction of a
    // millisecond before a minute shows the minute the formatter shows.
    guard let second = date.legacyFormatterWholeSecond else {
        return waterlooDateTimeFormatter().string(from: date)
    }
    return waterlooDateTimeStyle.format(second)
}
