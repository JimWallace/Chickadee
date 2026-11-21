// Tests/APITests/Gamification/LiveBoardETagTests.swift
//
// `LiveBoardETag.tag` without a database. The route tests in
// `LiveBoardRefreshTests` prove the 304 end to end, but they need Postgres.
// These pin the rule that the tag reads every part named in
// `LiveBoardETag.swift`: a change to any one part changes the tag, and a
// refresh inside the same time bucket keeps it.

import Foundation
import Testing

@testable import APIServer

@Suite struct LiveBoardETagTests {

    private static let viewer = UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")
    private static let start = Date(timeIntervalSince1970: 1_800_000_000)

    private static func tag(
        fingerprint: String = "rows-1",
        rosterDigest: String = "roster-1",
        viewerID: UUID? = viewer,
        isStaff: Bool = false,
        query: String = "fragment=body",
        windowState: String = "open",
        now: Date = start,
        build: String = "0.6.1"
    ) -> String {
        LiveBoardETag.tag(
            fingerprint: fingerprint, rosterDigest: rosterDigest,
            reader: LiveBoardETag.Reader(viewerID: viewerID, isStaff: isStaff, query: query),
            windowState: windowState, now: now, build: build)
    }

    @Test func theTagIsAWeakTagWithAFixedPrefix() throws {
        let tag = Self.tag()
        let match = try #require(tag.wholeMatch(of: /W\/"lb-([0-9a-f]+)"/))
        #expect(match.output.1.count == 32)
    }

    @Test func theSameInputsGiveTheSameTag() {
        #expect(Self.tag() == Self.tag())
    }

    @Test func eachPartChangesTheTag() {
        let base = Self.tag()
        let changed = [
            Self.tag(fingerprint: "rows-2"),
            Self.tag(rosterDigest: "roster-2"),
            Self.tag(viewerID: UUID(uuidString: "00000000-0000-0000-0000-0000000000B2")),
            Self.tag(viewerID: nil),
            Self.tag(isStaff: true),
            Self.tag(query: "fragment=body&all=1"),
            Self.tag(windowState: "closed"),
            Self.tag(build: "0.6.2"),
            Self.tag(now: Self.start.addingTimeInterval(LiveBoardETag.bucketSeconds)),
        ]
        for tag in changed {
            #expect(tag != base)
        }
        #expect(Set(changed).count == changed.count)
    }

    @Test func aRefreshInTheSameBucketKeepsTheTag() {
        let bucketStart = Date(
            timeIntervalSince1970: Double(LiveBoardETag.bucket(at: Self.start)) * LiveBoardETag.bucketSeconds)
        let late = bucketStart.addingTimeInterval(LiveBoardETag.bucketSeconds - 0.5)
        #expect(Self.tag(now: bucketStart) == Self.tag(now: late))
        #expect(Self.tag(now: late) != Self.tag(now: bucketStart.addingTimeInterval(LiveBoardETag.bucketSeconds)))
    }

    @Test func theBucketIsTheTimeDividedByTheBucketLengthRoundedDown() {
        #expect(LiveBoardETag.bucketSeconds == 30)
        #expect(LiveBoardETag.bucket(at: Date(timeIntervalSince1970: 0)) == 0)
        #expect(LiveBoardETag.bucket(at: Date(timeIntervalSince1970: 29.9)) == 0)
        #expect(LiveBoardETag.bucket(at: Date(timeIntervalSince1970: 30)) == 1)
        #expect(LiveBoardETag.bucket(at: Date(timeIntervalSince1970: 89)) == 2)
    }
}
