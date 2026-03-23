// Tests/APITests/UWImportantDatesTests.swift
//
// Unit tests for the iCalendar parsing functions used by UWImportantDatesCache.

import XCTest
@testable import chickadee_server
import Foundation

final class UWImportantDatesTests: XCTestCase {

    // MARK: - extractICSDate

    func testExtractDateValueDate() {
        let block = "DTSTART;VALUE=DATE:20260321\nDTEND;VALUE=DATE:20260322\n"
        XCTAssertEqual(extractICSDate(key: "DTSTART", from: block), "2026-03-21")
        XCTAssertEqual(extractICSDate(key: "DTEND", from: block), "2026-03-22")
    }

    func testExtractDatePlainColon() {
        let block = "DTSTART:20261225\n"
        XCTAssertEqual(extractICSDate(key: "DTSTART", from: block), "2026-12-25")
    }

    func testExtractDateWithTimestamp() {
        // Some feeds include a full datetime — we take the first 8 digits (the date)
        let block = "DTSTART:20260101T090000Z\n"
        XCTAssertEqual(extractICSDate(key: "DTSTART", from: block), "2026-01-01")
    }

    func testExtractDateMissing() {
        let block = "SUMMARY:Some event\n"
        XCTAssertNil(extractICSDate(key: "DTSTART", from: block))
    }

    func testExtractDateInvalidDigits() {
        let block = "DTSTART:abcdefgh\n"
        XCTAssertNil(extractICSDate(key: "DTSTART", from: block))
    }

    func testExtractDateTooShort() {
        let block = "DTSTART:2026031\n"  // 7 digits
        XCTAssertNil(extractICSDate(key: "DTSTART", from: block))
    }

    // MARK: - extractICSSummary

    func testExtractSummarySimple() {
        let block = "SUMMARY:Reading Week\nDTSTART:20260216\n"
        XCTAssertEqual(extractICSSummary(from: block), "Reading Week")
    }

    func testExtractSummaryFoldedLines() {
        // iCal folding: continuation lines start with a space that is stripped,
        // so the content joins directly (no extra space added).
        let block = "SUMMARY:University Closed\n - Holiday Observ\n ance Day\nDTSTART:20260101\n"
        XCTAssertEqual(extractICSSummary(from: block), "University Closed- Holiday Observance Day")
    }

    func testExtractSummaryWithTabContinuation() {
        let block = "SUMMARY:Final Exam\n\tination Period\nDTSTART:20260401\n"
        XCTAssertEqual(extractICSSummary(from: block), "Final Examination Period")
    }

    func testExtractSummaryUnescapesBackslash() {
        let block = "SUMMARY:Holiday\\, No Classes\\; Campus Closed\n"
        XCTAssertEqual(extractICSSummary(from: block), "Holiday, No Classes; Campus Closed")
    }

    func testExtractSummaryUnescapesNewlines() {
        let block = "SUMMARY:Line1\\nLine2\\NLine3\n"
        XCTAssertEqual(extractICSSummary(from: block), "Line1 Line2 Line3")
    }

    func testExtractSummaryWithSemicolonParams() {
        // SUMMARY;LANGUAGE=en:Christmas Day
        let block = "SUMMARY;LANGUAGE=en:Christmas Day\n"
        XCTAssertEqual(extractICSSummary(from: block), "Christmas Day")
    }

    func testExtractSummaryMissing() {
        let block = "DTSTART:20260101\nDTEND:20260102\n"
        XCTAssertNil(extractICSSummary(from: block))
    }

    func testExtractSummaryEmpty() {
        let block = "SUMMARY:\nDTSTART:20260101\n"
        XCTAssertNil(extractICSSummary(from: block))
    }

    // MARK: - isRelevantUWEvent

    func testRelevantHolidays() {
        XCTAssertTrue(isRelevantUWEvent("Good Friday"))
        XCTAssertTrue(isRelevantUWEvent("CHRISTMAS DAY"))
        XCTAssertTrue(isRelevantUWEvent("New Year's Day"))
        XCTAssertTrue(isRelevantUWEvent("Civic Holiday"))
        XCTAssertTrue(isRelevantUWEvent("Thanksgiving Day"))
    }

    func testRelevantBreaks() {
        XCTAssertTrue(isRelevantUWEvent("Reading Week"))
        XCTAssertTrue(isRelevantUWEvent("Spring Break"))
        XCTAssertTrue(isRelevantUWEvent("Winter Break begins"))
    }

    func testRelevantExams() {
        XCTAssertTrue(isRelevantUWEvent("Final Examination Period"))
        XCTAssertTrue(isRelevantUWEvent("Final Exam Period Begins"))
    }

    func testRelevantClosures() {
        XCTAssertTrue(isRelevantUWEvent("University Closed"))
        XCTAssertTrue(isRelevantUWEvent("Holiday Closure"))
    }

    func testIrrelevantEvents() {
        XCTAssertFalse(isRelevantUWEvent("Classes begin"))
        XCTAssertFalse(isRelevantUWEvent("Last day to add courses"))
        XCTAssertFalse(isRelevantUWEvent("Convocation"))
        XCTAssertFalse(isRelevantUWEvent("Fee payment deadline"))
    }

    // MARK: - nextDayISO

    func testNextDayNormal() {
        XCTAssertEqual(nextDayISO("2026-03-21"), "2026-03-22")
    }

    func testNextDayMonthBoundary() {
        XCTAssertEqual(nextDayISO("2026-01-31"), "2026-02-01")
    }

    func testNextDayYearBoundary() {
        XCTAssertEqual(nextDayISO("2025-12-31"), "2026-01-01")
    }

    func testNextDayLeapYear() {
        XCTAssertEqual(nextDayISO("2024-02-28"), "2024-02-29")
        XCTAssertEqual(nextDayISO("2024-02-29"), "2024-03-01")
    }

    func testNextDayInvalidDate() {
        // Invalid input returns the input unchanged
        XCTAssertEqual(nextDayISO("not-a-date"), "not-a-date")
    }

    // MARK: - parseICSEvents (full VEVENT parsing)

    func testParseFullICS() {
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
        XCTAssertEqual(events.count, 3)

        XCTAssertEqual(events[0].startDate, "2026-02-16")
        XCTAssertEqual(events[0].endDate, "2026-02-21")
        XCTAssertEqual(events[0].title, "Reading Week")

        XCTAssertEqual(events[1].startDate, "2026-04-03")
        XCTAssertEqual(events[1].title, "Good Friday")
        // No DTEND → defaults to next day
        XCTAssertEqual(events[1].endDate, "2026-04-04")
    }

    func testParseICSEmptyInput() {
        XCTAssertTrue(parseICSEvents("").isEmpty)
    }

    func testParseICSNoEvents() {
        let ics = "BEGIN:VCALENDAR\nVERSION:2.0\nEND:VCALENDAR"
        XCTAssertTrue(parseICSEvents(ics).isEmpty)
    }

    func testParseICSSkipsEventsWithoutDateOrSummary() {
        let ics = """
        BEGIN:VEVENT
        SUMMARY:No date event
        END:VEVENT
        BEGIN:VEVENT
        DTSTART:20260101
        END:VEVENT
        """
        // First has no date, second has no summary — both skipped
        XCTAssertTrue(parseICSEvents(ics).isEmpty)
    }
}
