// Tests/APITests/UWImportantDatesTests.swift
//
// Unit tests for the iCalendar parsing functions used by UWImportantDatesCache.

import Fluent
import Foundation
import Testing

@testable import APIServer

@Suite struct UWImportantDatesTests {

    // MARK: - extractICSDate

    @Test func extractDateValueDate() {
        let block = "DTSTART;VALUE=DATE:20260321\nDTEND;VALUE=DATE:20260322\n"
        #expect(extractICSDate(key: "DTSTART", from: block) == "2026-03-21")
        #expect(extractICSDate(key: "DTEND", from: block) == "2026-03-22")
    }

    @Test func extractDatePlainColon() {
        let block = "DTSTART:20261225\n"
        #expect(extractICSDate(key: "DTSTART", from: block) == "2026-12-25")
    }

    @Test func extractDateWithTimestamp() {
        // Some feeds include a full datetime — we take the first 8 digits (the date).
        let block = "DTSTART:20260101T090000Z\n"
        #expect(extractICSDate(key: "DTSTART", from: block) == "2026-01-01")
    }

    @Test func extractDateMissing() {
        let block = "SUMMARY:Some event\n"
        #expect(extractICSDate(key: "DTSTART", from: block) == nil)
    }

    @Test func extractDateInvalidDigits() {
        let block = "DTSTART:abcdefgh\n"
        #expect(extractICSDate(key: "DTSTART", from: block) == nil)
    }

    @Test func extractDateTooShort() {
        let block = "DTSTART:2026031\n"  // 7 digits
        #expect(extractICSDate(key: "DTSTART", from: block) == nil)
    }

    // MARK: - extractICSSummary

    @Test func extractSummarySimple() {
        let block = "SUMMARY:Reading Week\nDTSTART:20260216\n"
        #expect(extractICSSummary(from: block) == "Reading Week")
    }

    @Test func extractSummaryFoldedLines() {
        // iCal folding: continuation lines start with a space that is stripped,
        // so the content joins directly (no extra space added).
        let block = "SUMMARY:University Closed\n - Holiday Observ\n ance Day\nDTSTART:20260101\n"
        #expect(extractICSSummary(from: block) == "University Closed- Holiday Observance Day")
    }

    @Test func extractSummaryWithTabContinuation() {
        let block = "SUMMARY:Final Exam\n\tination Period\nDTSTART:20260401\n"
        #expect(extractICSSummary(from: block) == "Final Examination Period")
    }

    @Test func extractSummaryUnescapesBackslash() {
        let block = "SUMMARY:Holiday\\, No Classes\\; Campus Closed\n"
        #expect(extractICSSummary(from: block) == "Holiday, No Classes; Campus Closed")
    }

    @Test func extractSummaryUnescapesNewlines() {
        let block = "SUMMARY:Line1\\nLine2\\NLine3\n"
        #expect(extractICSSummary(from: block) == "Line1 Line2 Line3")
    }

    @Test func extractSummaryWithSemicolonParams() {
        // SUMMARY;LANGUAGE=en:Christmas Day
        let block = "SUMMARY;LANGUAGE=en:Christmas Day\n"
        #expect(extractICSSummary(from: block) == "Christmas Day")
    }

    @Test func extractSummaryMissing() {
        let block = "DTSTART:20260101\nDTEND:20260102\n"
        #expect(extractICSSummary(from: block) == nil)
    }

    @Test func extractSummaryEmpty() {
        let block = "SUMMARY:\nDTSTART:20260101\n"
        #expect(extractICSSummary(from: block) == nil)
    }

    // MARK: - isRelevantUWEvent

    @Test(arguments: [
        "Good Friday",
        "CHRISTMAS DAY",
        "New Year's Day",
        "Civic Holiday",
        "Thanksgiving Day",
        "Reading Week",
        "Spring Break",
        "Winter Break begins",
        "Final Examination Period",
        "Final Exam Period Begins",
        "University Closed",
        "Holiday Closure",
    ])
    func relevantEvent(summary: String) {
        #expect(isRelevantUWEvent(summary))
    }

    @Test(arguments: [
        "Classes begin",
        "Last day to add courses",
        "Convocation",
        "Fee payment deadline",
    ])
    func irrelevantEvent(summary: String) {
        #expect(!isRelevantUWEvent(summary))
    }

    // MARK: - nextDayISO

    @Test(
        arguments: zip(
            ["2026-03-21", "2026-01-31", "2025-12-31", "2024-02-28", "2024-02-29"],
            ["2026-03-22", "2026-02-01", "2026-01-01", "2024-02-29", "2024-03-01"]
        ))
    func nextDayAdvances(input: String, expected: String) {
        #expect(nextDayISO(input) == expected)
    }

    @Test func nextDayInvalidDateReturnsUnchanged() {
        #expect(nextDayISO("not-a-date") == "not-a-date")
    }

    // MARK: - parseICSEvents (full VEVENT parsing)

    @Test func parseFullICS() {
        let ics = """
            BEGIN:VCALENDAR
            VERSION:2.0
            BEGIN:VEVENT
            DTSTART;VALUE=DATE:20260216
            DTEND;VALUE=DATE:20260221
            SUMMARY:Reading Week
            END:VEVENT
            BEGIN:VEVENT
            DTSTART;VALUE=DATE:20260403
            SUMMARY:Good Friday
            END:VEVENT
            BEGIN:VEVENT
            DTSTART;VALUE=DATE:20260901
            SUMMARY:Classes begin
            END:VEVENT
            END:VCALENDAR
            """
        let events = parseICSEvents(ics)
        #expect(events.count == 3)

        #expect(events[0].startDate == "2026-02-16")
        #expect(events[0].endDate == "2026-02-21")
        #expect(events[0].title == "Reading Week")

        #expect(events[1].startDate == "2026-04-03")
        #expect(events[1].title == "Good Friday")
        // No DTEND → defaults to next day
        #expect(events[1].endDate == "2026-04-04")
    }

    @Test func parseICSEmptyInput() {
        #expect(parseICSEvents("").isEmpty)
    }

    @Test func parseICSNoEvents() {
        let ics = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR"
        #expect(parseICSEvents(ics).isEmpty)
    }

    @Test func parseICSSkipsEventsWithoutDateOrSummary() {
        let ics = """
            BEGIN:VEVENT
            SUMMARY:No date event
            END:VEVENT
            BEGIN:VEVENT
            DTSTART:20260101
            END:VEVENT
            """
        // First has no date, second has no summary — both skipped.
        #expect(parseICSEvents(ics).isEmpty)
    }
}
