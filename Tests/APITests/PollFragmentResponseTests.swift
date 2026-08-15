// Tests/APITests/PollFragmentResponseTests.swift
//
// The conditional-response contract for the three `?fragment=rows` poll
// endpoints. `table-poll.js` refetches them every five seconds for as long as
// a dashboard is open; without an ETag every one of those was a 200 carrying
// the whole table, and the client repainted its `<tbody>` from identical bytes.
//
// The properties that matter are all about STABILITY: the same rows must hash
// the same way on every process (so a load-balanced deployment does not
// alternate 200s), and different rows must not collide into a 304, which would
// leave a roster silently stale.

import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// Serialized: each test builds and tears down its own `Application` for the
/// bare `Request` these pure helpers take.
@Suite(.serialized) struct PollFragmentResponseTests {

    /// Runs `body` with a `Request` carrying the given `If-None-Match`.
    private func withRequest(
        ifNoneMatch: String? = nil,
        _ body: (Request) throws -> Void
    ) async throws {
        let app = try await Application.make(.testing)
        try await withApp(app) { app in
            var headers = HTTPHeaders()
            if let ifNoneMatch {
                headers.replaceOrAdd(name: .ifNoneMatch, value: ifNoneMatch)
            }
            let req = Request(
                application: app,
                method: .GET,
                url: "/rows?fragment=rows",
                headers: headers,
                on: app.eventLoopGroup.next()
            )
            try body(req)
        }
    }

    private func buffer(_ string: String) -> ByteBuffer {
        ByteBuffer(string: string)
    }

    /// The ETag the helper would mint for these bytes, without a request.
    private func etag(_ string: String) -> String {
        Response.weakETag(for: buffer(string))
    }

    @Test func firstRequestGetsRowsAndAnETag() async throws {
        try await withRequest { req in
            let response = Response.pollFragment(html: self.buffer("<tr>a</tr>"), for: req)
            #expect(response.status == .ok)
            let tag = try #require(response.headers.first(name: .eTag))
            #expect(tag.hasPrefix("W/\""))
            #expect(response.headers.first(name: .contentType)?.contains("text/html") == true)
        }
    }

    @Test func matchingETagAnswers304WithNoBody() async throws {
        try await withRequest(ifNoneMatch: etag("<tr>a</tr>")) { req in
            let response = Response.pollFragment(html: self.buffer("<tr>a</tr>"), for: req)
            #expect(response.status == .notModified)
            #expect(response.body.data?.isEmpty ?? true)
            #expect(response.headers.first(name: .eTag) == self.etag("<tr>a</tr>"))
        }
    }

    @Test func changedRowsAnswer200EvenWhenTheClientOffersAnETag() async throws {
        try await withRequest(ifNoneMatch: etag("<tr>a</tr>")) { req in
            let response = Response.pollFragment(html: self.buffer("<tr>b</tr>"), for: req)
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .eTag) == self.etag("<tr>b</tr>"))
        }
    }

    /// A conditional request may list several candidates.
    @Test func aListOfCandidatesIsHonoured() async throws {
        try await withRequest(ifNoneMatch: "W/\"stale\", \(etag("<tr>a</tr>"))") { req in
            #expect(Response.pollFragment(html: self.buffer("<tr>a</tr>"), for: req).status == .notModified)
        }
    }

    /// `*` matches any existing representation.
    @Test func theWildcardCandidateIsHonoured() async throws {
        try await withRequest(ifNoneMatch: "*") { req in
            #expect(Response.pollFragment(html: self.buffer("<tr>a</tr>"), for: req).status == .notModified)
        }
    }

    /// The ETag is a content hash, not a per-process value: two app processes
    /// behind a load balancer must agree, or every poll repaints whichever one
    /// it did not hit last. (Swift's `Hasher` is seeded per process, which is
    /// exactly why it is not used here.)
    @Test func theETagDependsOnlyOnTheBytes() {
        #expect(etag("<tr>a</tr>") == etag("<tr>a</tr>"))
        #expect(etag("<tr>a</tr>") != etag("<tr>b</tr>"))
        #expect(etag("").isEmpty == false, "even empty rows get a stable tag")
    }

    @Test func theEmptyFragmentAlsoRevalidates() async throws {
        try await withRequest(ifNoneMatch: etag("")) { req in
            let response = Response.emptyPollFragment(for: req)
            #expect(response.status == .notModified, "a client polling an empty table settles into 304s too")
        }
    }

    /// `no-cache` means revalidate, not "do not store" — the whole design
    /// depends on the client coming back with If-None-Match.
    @Test func fragmentsAskToBeRevalidated() async throws {
        try await withRequest { req in
            let response = Response.pollFragment(html: self.buffer("<tr>a</tr>"), for: req)
            #expect(response.headers.first(name: .cacheControl) == "no-cache")
        }
    }

    /// Whitespace around a listed candidate is normal in the wild.
    @Test func candidateWhitespaceIsTolerated() async throws {
        try await withRequest(ifNoneMatch: "   \(etag("<tr>a</tr>"))   ") { req in
            #expect(Response.pollFragment(html: self.buffer("<tr>a</tr>"), for: req).status == .notModified)
        }
    }
}
