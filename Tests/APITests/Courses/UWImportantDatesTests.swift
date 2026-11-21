// Tests/APITests/Courses/UWImportantDatesTests.swift
//
// `UWImportantDatesCache`: the iCalendar parsing functions, then the
// fetch-and-cache half.
//
// RFC 5545 requires CRLF line endings. In Swift "\r\n" is one `Character`, so
// on Linux `components(separatedBy: "\n")` did not split a CRLF feed, and the
// parser found no events in a standard feed. The line-ending tests feed the
// same iCalendar body with CRLF and with LF only, and expect the same events.
//
// `UWImportantDatesCacheFetchTests` drives `fetchDates` with a scripted Vapor
// `Client`, so nothing reaches uwaterloo.ca. It pins the feed URL, the
// relevance filter on a fetched feed, the 24-hour cache, and the two failure
// paths (a non-200 answer and a thrown error), which return the empty cache
// and do not start the cache clock.

import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

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

    // MARK: - Line endings

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

// MARK: - Fetch and cache

/// A `Client` that records each URL and answers with one scripted reply.
private final class UWFeedStubClient: Client, Sendable {
    enum Reply: Sendable {
        case answer(HTTPResponseStatus, String?)
        case failure
    }

    struct StubFailure: Error {}

    let eventLoop: any EventLoop
    let urls: NIOLockedValueBox<[String]>
    let reply: NIOLockedValueBox<Reply>

    init(eventLoop: any EventLoop, urls: NIOLockedValueBox<[String]>, reply: NIOLockedValueBox<Reply>) {
        self.eventLoop = eventLoop
        self.urls = urls
        self.reply = reply
    }

    func delegating(to eventLoop: any EventLoop) -> any Client {
        UWFeedStubClient(eventLoop: eventLoop, urls: urls, reply: reply)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        urls.withLockedValue { $0.append(request.url.string) }
        switch reply.withLockedValue({ $0 }) {
        case .failure:
            return eventLoop.makeFailedFuture(StubFailure())
        case .answer(let status, let body):
            return eventLoop.makeSucceededFuture(
                ClientResponse(status: status, headers: [:], body: body.map { ByteBuffer(string: $0) }))
        }
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) final class UWImportantDatesCacheFetchTests {
    static let feedURL = "https://uwaterloo.ca/important-dates/important-dates/important_dates_ical.ics"

    /// Two relevant events (a break and a holiday) and one irrelevant event
    /// (a deadline). The lines end in LF only: on Linux the parser does not
    /// split CRLF lines, because `components(separatedBy: "\n")` does not
    /// split inside the one-Character "\r\n". That is a product bug, reported
    /// in the pull request and not tested here.
    static let feed = """
        BEGIN:VCALENDAR
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270215
        DTEND;VALUE=DATE:20270222
        SUMMARY:Reading week
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270110
        SUMMARY:Last day to add a course
        END:VEVENT
        BEGIN:VEVENT
        DTSTART;VALUE=DATE:20270402
        SUMMARY:Good Friday\\, university closed
        END:VEVENT
        END:VCALENDAR
        """

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-uw-dates-fetch")
    }

    private func stub(
        _ reply: UWFeedStubClient.Reply
    ) -> (client: UWFeedStubClient, urls: NIOLockedValueBox<[String]>, reply: NIOLockedValueBox<UWFeedStubClient.Reply>)
    {
        let urls = NIOLockedValueBox<[String]>([])
        let box = NIOLockedValueBox(reply)
        return (UWFeedStubClient(eventLoop: app.eventLoopGroup.next(), urls: urls, reply: box), urls, box)
    }

    @Test func aFetchedFeedKeepsOnlyTheRelevantEventsAndIsCached() async throws {
        try await withApp(app) { app in
            let (client, urls, reply) = stub(.answer(.ok, Self.feed))
            let cache = UWImportantDatesCache()

            let first = await cache.fetchDates(client: client, logger: app.logger)
            #expect(first.map(\.title) == ["Reading week", "Good Friday, university closed"])
            #expect(first.first?.startDate == "2027-02-15")
            #expect(first.first?.endDate == "2027-02-22")
            // No DTEND: the end is the next day.
            #expect(first.last?.endDate == "2027-04-03")
            #expect(urls.withLockedValue { $0 } == [Self.feedURL])

            // Inside the 24-hour window the cache answers, even when the feed
            // would now fail.
            reply.withLockedValue { $0 = .failure }
            let second = await cache.fetchDates(client: client, logger: app.logger)
            #expect(second.map(\.title) == first.map(\.title))
            #expect(urls.withLockedValue { $0.count } == 1)
        }
    }

    @Test func aNon200AnswerReturnsTheEmptyCacheAndDoesNotStartTheClock() async throws {
        try await withApp(app) { app in
            let (client, urls, reply) = stub(.answer(.serviceUnavailable, "down"))
            let cache = UWImportantDatesCache()

            #expect(await cache.fetchDates(client: client, logger: app.logger).isEmpty)

            // The failure was not cached: the next call asks the feed again.
            reply.withLockedValue { $0 = .answer(.ok, Self.feed) }
            #expect(await cache.fetchDates(client: client, logger: app.logger).count == 2)
            #expect(urls.withLockedValue { $0.count } == 2)
        }
    }

    @Test func aThrownErrorReturnsTheEmptyCacheAndDoesNotStartTheClock() async throws {
        try await withApp(app) { app in
            let (client, urls, reply) = stub(.failure)
            let cache = UWImportantDatesCache()

            #expect(await cache.fetchDates(client: client, logger: app.logger).isEmpty)

            reply.withLockedValue { $0 = .answer(.ok, Self.feed) }
            #expect(await cache.fetchDates(client: client, logger: app.logger).count == 2)
            #expect(urls.withLockedValue { $0.count } == 2)
        }
    }

    @Test func anEmptyBodyIsAnEmptyFeedAndIsCached() async throws {
        try await withApp(app) { app in
            let (client, urls, reply) = stub(.answer(.ok, nil))
            let cache = UWImportantDatesCache()

            #expect(await cache.fetchDates(client: client, logger: app.logger).isEmpty)

            // A 200 with no events still starts the clock.
            reply.withLockedValue { $0 = .answer(.ok, Self.feed) }
            #expect(await cache.fetchDates(client: client, logger: app.logger).isEmpty)
            #expect(urls.withLockedValue { $0.count } == 1)
        }
    }

    @Test func theApplicationKeepsOneCache() async throws {
        try await withApp(app) { app in
            let (client, urls, _) = stub(.answer(.ok, Self.feed))
            #expect(await app.uwImportantDatesCache.fetchDates(client: client, logger: app.logger).count == 2)
            // The same actor answers the second read from its cache.
            #expect(await app.uwImportantDatesCache.fetchDates(client: client, logger: app.logger).count == 2)
            #expect(urls.withLockedValue { $0.count } == 1)

            app.uwImportantDatesCache = UWImportantDatesCache()
            #expect(await app.uwImportantDatesCache.fetchDates(client: client, logger: app.logger).count == 2)
            #expect(urls.withLockedValue { $0.count } == 2)
        }
    }
}
