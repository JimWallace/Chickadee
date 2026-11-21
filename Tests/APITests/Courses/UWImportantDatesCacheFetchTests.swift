// Tests/APITests/Courses/UWImportantDatesCacheFetchTests.swift
//
// The fetch-and-cache half of `UWImportantDatesCache`. `UWImportantDatesTests`
// covers the iCalendar parsing; this suite drives `fetchDates` with a scripted
// Vapor `Client`, so nothing reaches uwaterloo.ca. It pins the feed URL, the
// relevance filter on a fetched feed, the 24-hour cache, and the two failure
// paths (a non-200 answer and a thrown error), which return the empty cache
// and do not start the cache clock.

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

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
