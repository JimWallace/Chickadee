// Tests/APITests/BrightSpaceTransportTests.swift
//
// Pins the D2L Valence request-transport layer ported from UW's reference
// client (learn_api / d2lvalence): signing-path extraction, list pagination
// (both Valence conventions), and the clock-skew error parse. None of these
// hit a live D2L — they exercise the pure helpers the actor composes, so a
// regression in the URL/JSON contract fails here instead of only in prod.

import Foundation
import Testing

@testable import APIServer

@Suite struct BrightSpaceTransportTests {

    // MARK: - Signing path extraction

    @Test func valencePath_stripsQueryHostAndDecodes() {
        // Full URL with a query → path only, query dropped.
        #expect(
            valencePath(of: "https://learntest.uwaterloo.ca/d2l/api/lp/1.47/users/?orgDefinedId=12345")
                == "/d2l/api/lp/1.47/users/")
        // Host with an explicit port.
        #expect(
            valencePath(of: "https://host:443/d2l/api/le/1.75/grades/") == "/d2l/api/le/1.75/grades/")
        // Fragment dropped.
        #expect(valencePath(of: "https://h/a/b#frag") == "/a/b")
        // Already a bare path (no scheme) — returned unchanged.
        #expect(
            valencePath(of: "/d2l/api/lp/1.47/users/whoami") == "/d2l/api/lp/1.47/users/whoami")
        // Host with no path component.
        #expect(valencePath(of: "https://host") == "/")
        // Percent-encoded path is decoded (mirrors unquote_plus on the server).
        #expect(
            valencePath(of: "https://h/d2l/api/le/1.75/o%20u/classlist/paged/")
                == "/d2l/api/le/1.75/o u/classlist/paged/")
    }

    @Test func valencePath_feedsBaseStringIdenticallyToReference() {
        // The whole point of the extractor: signing a full URL yields the same
        // base string the reference client computes from the path alone.
        let full = "https://learntest.uwaterloo.ca/d2l/api/lp/1.47/users/whoami"
        let base = valenceRequestBaseString(
            method: "GET", path: valencePath(of: full), timestamp: 1_700_000_000)
        #expect(base == "GET&/d2l/api/lp/1.47/users/whoami&1700000000")
    }

    // MARK: - Pagination (bookmark convention)

    @Test func nextPageURL_bookmarkConvention_followsWhileMoreItems() {
        let first = "https://h/d2l/api/le/1.75/1106038/classlist/paged/"
        // HasMoreItems → re-issue the base URL with the bookmark.
        #expect(
            valenceNextPageURL(
                firstPageURL: first, baseURL: "https://h",
                pagingBookmark: "abc", pagingHasMore: true, next: nil)
                == "\(first)?bookmark=abc")
        // No more items → done.
        #expect(
            valenceNextPageURL(
                firstPageURL: first, baseURL: "https://h",
                pagingBookmark: "abc", pagingHasMore: false, next: nil) == nil)
        // PagingInfo present but empty bookmark → done (don't loop forever).
        #expect(
            valenceNextPageURL(
                firstPageURL: first, baseURL: "https://h",
                pagingBookmark: "", pagingHasMore: true, next: nil) == nil)
    }

    @Test func nextPageURL_bookmark_isPercentEncodedAndReplacesPriorQuery() {
        // A bookmark with reserved characters is encoded; any existing query on
        // the first-page URL is replaced (not appended) so bookmarks don't stack.
        let url = valenceNextPageURL(
            firstPageURL: "https://h/d2l/api/le/1.75/1/classlist/paged/?bookmark=old",
            baseURL: "https://h",
            pagingBookmark: "a b/c", pagingHasMore: true, next: nil)
        #expect(url == "https://h/d2l/api/le/1.75/1/classlist/paged/?bookmark=a%20b/c")
    }

    // MARK: - Pagination (continuation-URL convention)

    @Test func nextPageURL_nextConvention_absoluteAndRelative() {
        // Absolute Next URL is used verbatim.
        let absolute = "https://h/d2l/api/le/1.75/1/classlist/paged/?bookmark=z"
        #expect(
            valenceNextPageURL(
                firstPageURL: "ignored", baseURL: "https://h",
                pagingBookmark: nil, pagingHasMore: nil, next: absolute) == absolute)
        // Relative Next (leading slash) is resolved against the host.
        #expect(
            valenceNextPageURL(
                firstPageURL: "ignored", baseURL: "https://h",
                pagingBookmark: nil, pagingHasMore: nil, next: "/d2l/api/x?bookmark=z")
                == "https://h/d2l/api/x?bookmark=z")
        // Relative Next without a leading slash still resolves.
        #expect(
            valenceNextPageURL(
                firstPageURL: "ignored", baseURL: "https://h",
                pagingBookmark: nil, pagingHasMore: nil, next: "d2l/api/x")
                == "https://h/d2l/api/x")
    }

    @Test func nextPageURL_singlePage_isNil() {
        // No PagingInfo and no Next (e.g. a plain object) → no further pages.
        #expect(
            valenceNextPageURL(
                firstPageURL: "https://h/x", baseURL: "https://h",
                pagingBookmark: nil, pagingHasMore: nil, next: nil) == nil)
    }

    // MARK: - Paged envelope decoding (D2L key contract)

    @Test func pagedEnvelope_decodesBookmarkStyle() throws {
        let json = """
            {
              "Items": [
                { "OrgDefinedId": "20771234", "Username": "jdoe" },
                { "OrgDefinedId": "20775678", "Username": "asmith" }
              ],
              "PagingInfo": { "Bookmark": "bm-2", "HasMoreItems": true }
            }
            """
        struct Row: Decodable {
            let orgDefinedId: String?
            let username: String?
            enum CodingKeys: String, CodingKey {
                case orgDefinedId = "OrgDefinedId"
                case username = "Username"
            }
        }
        let env = try JSONDecoder().decode(
            ValencePagedEnvelope<Row>.self, from: Data(json.utf8))
        #expect(env.elements.count == 2)
        #expect(env.elements.first?.username == "jdoe")
        #expect(env.pagingInfo?.bookmark == "bm-2")
        #expect(env.pagingInfo?.hasMoreItems == true)
    }

    @Test func pagedEnvelope_decodesObjectsNextStyle() throws {
        let json = """
            { "Objects": [ { "Id": 7 } ], "Next": "/d2l/api/x?bookmark=z" }
            """
        struct Row: Decodable {
            let id: Int
            enum CodingKeys: String, CodingKey { case id = "Id" }
        }
        let env = try JSONDecoder().decode(
            ValencePagedEnvelope<Row>.self, from: Data(json.utf8))
        #expect(env.elements.map(\.id) == [7])
        #expect(env.pagingInfo == nil)
        #expect(env.next == "/d2l/api/x?bookmark=z")
    }

    // MARK: - Clock-skew error parse

    @Test func serverTimeFromTimestampError_extractsServerTime() {
        #expect(
            valenceServerTimeFromTimestampError(body: "Timestamp out of range, 1700000000")
                == 1_700_000_000)
        // Tolerant of missing space and of case.
        #expect(
            valenceServerTimeFromTimestampError(body: "Timestamp out of range,1700000000")
                == 1_700_000_000)
        #expect(
            valenceServerTimeFromTimestampError(body: "timestamp out of range 1700000000")
                == 1_700_000_000)
    }

    @Test func serverTimeFromTimestampError_nilOnNonTimestamp403() {
        // A genuine permission/auth 403 must NOT be mistaken for a skew error
        // (otherwise we'd silently retry instead of surfacing it).
        #expect(valenceServerTimeFromTimestampError(body: "Invalid token") == nil)
        #expect(valenceServerTimeFromTimestampError(body: "") == nil)
        // The phrase without a trailing number yields no usable server time.
        #expect(valenceServerTimeFromTimestampError(body: "Timestamp out of range") == nil)
    }

    // MARK: - Version fallback floor

    @Test func fallbackAPIVersions_matchReferenceKnownGood() {
        // Negotiation prefers the server's LatestVersion; when discovery is
        // unavailable these UW-known-good floors are used (reference client pins).
        #expect(BrightSpaceSyncConfig.leAPIVersion == "1.75")
        #expect(BrightSpaceSyncConfig.lpAPIVersion == "1.47")
    }
}
