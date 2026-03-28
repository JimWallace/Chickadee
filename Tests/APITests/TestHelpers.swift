// Tests/APITests/TestHelpers.swift
//
// Shared helpers for integration tests that involve session auth and CSRF.

import XCTest
import XCTVapor
import CSRF
import Crypto
import Leaf
import LeafKit
@testable import chickadee_server
import FluentSQLiteDriver
import Foundation

// MARK: - Async app lifecycle

/// Runs an async test body with a Vapor application and always shuts it down.
func withApp(_ app: Application, _ body: (Application) async throws -> Void) async throws {
    do {
        try await body(app)
        try await app.asyncShutdown()
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
}

extension Application {
    @discardableResult
    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        afterResponse: (XCTHTTPResponse) throws -> Void
    ) async throws -> XCTApplicationTester {
        try await self.asyncTest(
            method: runnerMethod,
            method,
            path,
            headers: headers,
            body: body,
            file: file,
            line: line,
            beforeRequest: { _ in },
            afterResponse: afterResponse
        )
    }

    @discardableResult
    func asyncTest(
        method runnerMethod: Method = .inMemory,
        _ method: HTTPMethod,
        _ path: String,
        headers: HTTPHeaders = [:],
        body: ByteBuffer? = nil,
        file: StaticString = #filePath,
        line: UInt = #line,
        beforeRequest: (inout XCTHTTPRequest) throws -> Void = { _ in },
        afterResponse: (XCTHTTPResponse) throws -> Void = { _ in }
    ) async throws -> XCTApplicationTester {
        let tester = try self.testable(method: runnerMethod)
        return try await tester.test(
            method,
            path,
            headers: headers,
            body: body,
            file: file,
            line: line,
            beforeRequest: { request async throws in
                try beforeRequest(&request)
            },
            afterResponse: { response async throws in
                try afterResponse(response)
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
        beforeRequest: (inout XCTHTTPRequest) throws -> Void = { _ in }
    ) async throws -> XCTHTTPResponse {
        var captured: XCTHTTPResponse?
        try await self.asyncTest(
            method, path,
            headers: headers,
            body: body,
            beforeRequest: beforeRequest,
            afterResponse: { captured = $0 }
        )
        return captured!
    }
}

// MARK: - Leaf / CSRF setup

/// Call in test setUp — after session middleware, before routes() — to enable
/// Leaf rendering. Required so that GET requests to form pages produce HTML
/// containing the `#csrfFormField()` hidden input, which is how tests obtain
/// a valid session-bound CSRF token.
func configureLeaf(_ app: Application) {
    // LeafKit's sandbox rejects any path that contains a hidden directory component
    // (e.g. ".claude"). When running from a git worktree under .claude, create a
    // symlink from a clean temp path so the string-level path checks pass.
    let viewsDir = app.directory.viewsDirectory
    if viewsDir.contains("/.") {
        let cleanPath = NSTemporaryDirectory() + "chickadee-leaf-\(UUID().uuidString)"
        try? FileManager.default.removeItem(atPath: cleanPath)
        try? FileManager.default.createSymbolicLink(atPath: cleanPath, withDestinationPath: viewsDir)
        app.leaf.configuration = LeafConfiguration(rootDirectory: cleanPath + "/")
    }
    app.views.use(.leaf)
    app.leaf.tags["csrfFormField"] = CSRFFormFieldTag()
}

// MARK: - CSRF token extraction

/// Parses the CSRF token from a rendered Leaf form page.
/// Looks for the hidden input rendered by `#csrfFormField()`:
///   `<input type='hidden' name='_csrf' value='TOKEN'>`
func extractCSRFToken(from html: String) -> String {
    guard let range = html.range(of: "name='_csrf' value='") else { return "" }
    let start = range.upperBound
    guard let end = html[start...].firstIndex(of: "'") else { return "" }
    return String(html[start..<end])
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
    try await app.asyncTest(.GET, path, beforeRequest: { req in
        if !cookie.isEmpty { req.headers.add(name: .cookie, value: cookie) }
    }, afterResponse: { res in
        if let c = res.headers.first(name: .setCookie) { outCookie = c }
        outToken = extractCSRFToken(from: res.body.string)
    })
    return (outToken, outCookie)
}

// MARK: - Worker HMAC auth helper

/// Generates HMAC-signed HTTPHeaders for worker requests in tests.
/// Produces the same signature that WorkerHMACAuthMiddleware expects.
func workerHMACHeaders(
    method: HTTPMethod,
    path: String,
    body: ByteBuffer? = nil,
    workerSecret: String,
    workerID: String = "test-runner"
) -> HTTPHeaders {
    let timestamp = Int64(Date().timeIntervalSince1970)
    let nonce = UUID().uuidString

    var bodyCopy = body ?? ByteBuffer()
    let bodyBytes = bodyCopy.readBytes(length: bodyCopy.readableBytes) ?? []
    let bodyHash = Data(SHA256.hash(data: Data(bodyBytes))).hexEncodedString()

    let payload = [
        method.rawValue.uppercased(),
        path,
        bodyHash,
        String(timestamp),
        nonce
    ].joined(separator: "\n")

    let key = SymmetricKey(data: Data(workerSecret.utf8))
    let mac = HMAC<SHA256>.authenticationCode(for: Data(payload.utf8), using: key)
    let signature = Data(mac).hexEncodedString()

    var headers = HTTPHeaders()
    headers.add(name: "X-Worker-Timestamp", value: String(timestamp))
    headers.add(name: "X-Worker-Nonce",     value: nonce)
    headers.add(name: "X-Worker-Signature", value: signature)
    headers.add(name: "X-Worker-Id",        value: workerID)
    headers.contentType = .json
    return headers
}

private extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Login helper

/// Creates `username` in the database (if not already present) with `role`,
/// then performs the full two-step GET /login → POST /login flow so the CSRF
/// token is valid. Returns the authenticated session cookie.
@discardableResult
func loginUser(
    username: String,
    password: String,
    role: String,
    on app: Application
) async throws -> String {
    if try await APIUser.query(on: app.db).filter(\.$username == username).first() == nil {
        let hash = try Bcrypt.hash(password)
        let user = APIUser(username: username, passwordHash: hash, role: role)
        try await user.save(on: app.db)
    }

    // Step 1: GET /login to generate a session and CSRF token.
    let (token, sessionCookie) = try await csrfFields(for: "/login", on: app)

    // Step 2: POST /login with the CSRF token bound to that session.
    var authCookie = sessionCookie
    try await app.asyncTest(.POST, "/login", beforeRequest: { req in
        req.headers.add(name: .cookie, value: sessionCookie)
        try req.content.encode(
            ["username": username, "password": password, "_csrf": token],
            as: .urlEncodedForm
        )
    }, afterResponse: { res in
        // Use the new cookie if the session was rotated, otherwise keep the old one.
        if let c = res.headers.first(name: .setCookie) { authCookie = c }
    })
    return authCookie
}
