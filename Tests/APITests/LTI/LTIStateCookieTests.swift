// Tests/APITests/LTI/LTIStateCookieTests.swift
//
// The launch-state cookie is `Partitioned` over HTTPS (docs/lti-1-3.md "Deep
// Linking"), so a browser keeps it inside the LMS frame that the content
// picker opens in.

import Testing

@testable import APIServer

@Suite struct LTIStateCookieTests {
    static let values = [
        "\(LTIRoutes.stateCookieName)=abc; Max-Age=300; Path=/lti; Secure; HttpOnly; SameSite=None",
        "vapor-session=xyz; Path=/; HttpOnly; SameSite=Lax",
    ]

    @Test func onlyTheStateCookieIsPartitioned() {
        let secure = LTIRoutes.partitionedSetCookies(Self.values, secure: true)
        #expect(secure[0].hasSuffix("; Partitioned"))
        #expect(secure[1] == Self.values[1])
    }

    @Test func partitioningTwiceAddsNothing() {
        let once = LTIRoutes.partitionedSetCookies(Self.values, secure: true)
        #expect(LTIRoutes.partitionedSetCookies(once, secure: true) == once)
    }

    /// A partitioned cookie must be `Secure`; over plain http a browser would
    /// reject it, so none is sent.
    @Test func plainHTTPIsLeftAlone() {
        #expect(LTIRoutes.partitionedSetCookies(Self.values, secure: false) == Self.values)
    }
}
