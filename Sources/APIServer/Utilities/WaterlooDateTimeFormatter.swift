// APIServer/Utilities/WaterlooDateTimeFormatter.swift
//
// The one display formatter for a timestamp shown to a person: Canadian
// English, Waterloo local time, medium date and short time. Every page that
// prints a date calls it, so the five-drifted-display-sites bug class (#1118)
// cannot return. Lived in Routes/Web/AssignmentHelpers.swift until #2143;
// the course timeline and the BrightSpace presenter call it from below the
// routes.

import Foundation

func waterlooDateTimeFormatter() -> DateFormatter {
    let fmt = DateFormatter()
    fmt.locale = Locale(identifier: "en_CA")
    fmt.timeZone = TimeZone(identifier: "America/Toronto")
    fmt.dateStyle = .medium
    fmt.timeStyle = .short
    return fmt
}
