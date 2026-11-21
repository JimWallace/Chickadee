// Tests/APITests/Courses/UWImportantDatesLineEndingTests.swift
//
// RFC 5545 requires CRLF line endings. In Swift "\r\n" is one `Character`, so
// on Linux `components(separatedBy: "\n")` did not split a CRLF feed, and the
// parser found no events in a standard feed. These tests feed the same
// iCalendar body with CRLF and with LF only, and expect the same events.

import Foundation
import Testing

@testable import APIServer

@Suite struct UWImportantDatesLineEndingTests {
    /// Three events. The second has a folded SUMMARY and no DTEND.
    static let lines = [
        "BEGIN:VCALENDAR",
        "VERSION:2.0",
        "BEGIN:VEVENT",
        "UID:reading-week@example",
        "DTSTART;VALUE=DATE:20270215",
        "DTEND;VALUE=DATE:20270222",
        "SUMMARY:Reading week",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:good-friday@example",
        "DTSTART;VALUE=DATE:20270402",
        "SUMMARY:Good Friday\\, univ",
        " ersity closed",
        "END:VEVENT",
        "BEGIN:VEVENT",
        "UID:exams@example",
        "DTSTART:20270410T090000Z",
        "DTEND:20270428T170000Z",
        "SUMMARY;LANGUAGE=en:Final examination period",
        "END:VEVENT",
        "END:VCALENDAR",
    ]

    struct Event: Equatable {
        let startDate: String
        let endDate: String
        let title: String
    }

    static let expected = [
        Event(startDate: "2027-02-15", endDate: "2027-02-22", title: "Reading week"),
        Event(startDate: "2027-04-02", endDate: "2027-04-03", title: "Good Friday, university closed"),
        Event(startDate: "2027-04-10", endDate: "2027-04-28", title: "Final examination period"),
    ]

    static func parse(_ text: String) -> [Event] {
        parseICSEvents(text).map { Event(startDate: $0.startDate, endDate: $0.endDate, title: $0.title) }
    }

    @Test(arguments: ["\r\n", "\n", "\r"])
    func everyLineEndingGivesTheSameEvents(_ ending: String) {
        let body = Self.lines.joined(separator: ending) + ending
        #expect(Self.parse(body) == Self.expected)
    }

    @Test func aCRLFBlockGivesTheDateAndTheFoldedSummary() {
        let block = "\r\nDTSTART;VALUE=DATE:20270402\r\nSUMMARY:Good Friday\r\n  closure\r\nEND:VEVENT\r\n"
        #expect(extractICSDate(key: "DTSTART", from: block) == "2027-04-02")
        #expect(extractICSSummary(from: block) == "Good Friday closure")
    }

    @Test func aBlankLineStillEndsAFoldedSummary() {
        let block = "SUMMARY:Reading week\r\n\r\n extra\r\n"
        #expect(extractICSSummary(from: block) == "Reading week")
    }
}
