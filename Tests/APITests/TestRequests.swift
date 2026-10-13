// Tests/APITests/TestRequests.swift
//
// Sends requests to a test application and reads the CSRF token from a page.
//
// This file is the one place the tests touch VaporTesting's request API and
// build a `Request` on an event loop. Vapor 5 rewrites VaporTesting and has
// no event loops, so the move changes this file, not the tests that call it
// (docs/vapor-5-migration.md). `scripts/check-vapor5-readiness.sh` fails
// `format-lint` on a direct use elsewhere under Tests/.

import Foundation
import Testing
import VaporTesting

/// The request a test edits before it is sent.
typealias TestRequest = TestingHTTPRequest

/// The response a test reads.
typealias TestResponse = TestingHTTPResponse

/// A bare request against `app`, for code under test that takes a `Request`.
func makeTestRequest(
    on app: Application,
    method: HTTPMethod = .GET,
    url: URI = "/",
    headers: HTTPHeaders = [:]
) -> Request {
    Request(application: app, method: method, url: url, headers: headers, on: app.eventLoopGroup.any())
}

extension Application {
    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        afterResponse: (TestResponse) async throws -> Void
    ) async throws {
        try await self.asyncTest(
            method: runnerMethod,
            method,
            path,
            headers: headers,
            body: body,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            beforeRequest: { _ in },
            afterResponse: afterResponse
        )
    }

    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        fileID: String = #fileID,
        filePath: String = #filePath,
        line: Int = #line,
        column: Int = #column,
        beforeRequest: (inout TestRequest) async throws -> Void = { _ in },
        afterResponse: (TestResponse) async throws -> Void = { _ in }
    ) async throws {
        // Boot through the async path first. `testing()` boots with the
        // synchronous `boot()`, which runs no async lifecycle hook; Vapor 5
        // boots its test apps async too. A booted app is not booted again.
        try await self.asyncBoot()
        let tester = try self.testing(method: runnerMethod)
        _ = try await tester.test(
            method,
            path,
            headers: headers,
            body: body,
            fileID: fileID,
            filePath: filePath,
            line: line,
            column: column,
            beforeRequest: { request async throws in
                try await beforeRequest(&request)
            },
            afterResponse: { response async throws in
                try await afterResponse(response)
            }
        )
    }

    /// Fire a request and return the response directly, without a callback.
    /// Useful for concurrent tests where multiple responses must be collected.
    func asyncSendRequest(
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        beforeRequest: (inout TestRequest) async throws -> Void = { _ in }
    ) async throws -> TestResponse {
        var captured: TestResponse?
        try await self.asyncTest(
            method, path,
            headers: headers,
            body: body,
            beforeRequest: beforeRequest,
            afterResponse: { captured = $0 }
        )
        return try #require(captured)
    }
}

// MARK: - CSRF token extraction

/// Parses the CSRF token from a rendered form page.
/// Looks for the hidden input rendered by the Elementary `CSRFField`
/// (`<input type="hidden" name="_csrf" value="TOKEN">`), and also accepts the
/// single-quoted spelling.
func extractCSRFToken(from html: String) -> String {
    for quote in ["'", "\""] {
        guard let range = html.range(of: "name=\(quote)_csrf\(quote) value=\(quote)") else { continue }
        let start = range.upperBound
        guard let end = html[start...].firstIndex(of: Character(quote)) else { return "" }
        return String(html[start..<end])
    }
    return ""
}

/// GETs `path` and returns the CSRF token embedded in the rendered form HTML,
/// along with the session cookie (creating one on first call, or reusing the
/// supplied `cookie` to stay in the same session).
func csrfFields(
    for path: String,
    cookie: String = "",
    on app: Application
) async throws -> (token: String, cookie: String) {
    var outToken = ""
    var outCookie = cookie
    try await app.asyncTest(
        .GET, path,
        beforeRequest: { req in
            if !cookie.isEmpty { req.headers.add(name: .cookie, value: cookie) }
        },
        afterResponse: { res in
            if let c = res.headers.first(name: .setCookie) { outCookie = c }
            outToken = extractCSRFToken(from: res.body.string)
        })
    return (outToken, outCookie)
}
