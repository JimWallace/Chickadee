// Tests/APITests/Pages/ErrorPageBackLinkTests.swift
//
// The error page's "Go back" link (`sameOriginReferer`) only ever points at a
// plain server-relative path. A same-origin referer whose path starts with
// `//`, or holds a backslash, would make a protocol-relative href that a
// browser follows off-site, so it gets no link.

import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite struct ErrorPageBackLinkTests {

    @Test(arguments: ["/", "/instructor", "/submissions/abc", "/a/b//c"])
    func aPlainPathIsSafe(path: String) {
        #expect(isSafeLocalPath(path))
    }

    @Test(arguments: ["", "//evil.example", "//evil.example/x", "/\\evil.example", "\\\\evil.example", "/a\\b", "x/y"])
    func aProtocolRelativeOrBackslashPathIsRefused(path: String) {
        #expect(!isSafeLocalPath(path))
    }

    /// The back link the error page would show for `referer` on a request to
    /// `/missing` at `chickadee.test`.
    private func backLink(referer: String) async throws -> String? {
        var link: String?
        try await withApp(try await Application.make(.testing)) { app in
            var headers = HTTPHeaders()
            headers.add(name: .host, value: "chickadee.test")
            headers.add(name: .referer, value: referer)
            let request = Request(
                application: app, method: .GET, url: URI(string: "/missing"), headers: headers,
                on: app.eventLoopGroup.next())
            link = sameOriginReferer(of: request)
        }
        return link
    }

    @Test func aSameOriginRefererGetsALink() async throws {
        #expect(try await backLink(referer: "https://chickadee.test/instructor?tab=1") == "/instructor?tab=1")
    }

    @Test func anotherOriginGetsNoLink() async throws {
        #expect(try await backLink(referer: "https://evil.example/instructor") == nil)
    }

    @Test(arguments: [
        "https://chickadee.test//evil.example/x",
        "https://chickadee.test/%2Fevil.example",
        "https://chickadee.test/%5Cevil.example",
        "https://chickadee.test/%2F%2Fevil.example",
    ])
    func aSameOriginRefererWithAnUnsafePathGetsNoLink(referer: String) async throws {
        #expect(try await backLink(referer: referer) == nil)
    }
}
