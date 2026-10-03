// APIServer/Utilities/DayGrouper.swift
//
// Groups rows that arrive newest first into days, labelled "Today",
// "Yesterday" or "Sep 26" in the server's display time zone. The instructor
// activity timeline, the admin audit log and the health-alert firings all read
// the same way, so they share this one grouping.

import Foundation

/// One day's rows under a heading.
struct DayGroup<Row: Encodable & Sendable>: Encodable, Sendable {
    let label: String
    let rows: [Row]
}

enum DayGrouper {

    /// The zone the site speaks in. Days are cut here, not in UTC, so "Today"
    /// turns over at local midnight.
    static var displayTimeZone: TimeZone {
        TimeZone(identifier: "America/Toronto") ?? .current
    }

    /// Groups `rows` (already newest first) by the day `occurredAt` falls on in
    /// `timeZone`. `now` is a parameter so the midnight boundary can be tested.
    static func group<Row: Encodable & Sendable>(
        _ rows: [Row],
        occurredAt: (Row) -> Date,
        now: Date = Date(),
        timeZone: TimeZone = displayTimeZone
    ) -> [DayGroup<Row>] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: today) ?? today
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_CA")
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("MMM d")

        var days: [DayGroup<Row>] = []
        var currentStart: Date?
        var currentLabel = ""
        var bucket: [Row] = []
        func flush() {
            if !bucket.isEmpty { days.append(DayGroup(label: currentLabel, rows: bucket)) }
            bucket = []
        }
        for row in rows {
            let start = calendar.startOfDay(for: occurredAt(row))
            if start != currentStart {
                flush()
                currentStart = start
                if start == today {
                    currentLabel = "Today"
                } else if start == yesterday {
                    currentLabel = "Yesterday"
                } else {
                    currentLabel = formatter.string(from: start)
                }
            }
            bucket.append(row)
        }
        flush()
        return days
    }
}
