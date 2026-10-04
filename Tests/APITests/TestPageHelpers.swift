// Tests/APITests/TestPageHelpers.swift
//
// Two helpers that many page tests share: sign in as an admin, and GET a page
// with a session cookie and return its HTML. About thirty suites used to
// carry a private copy of one or both.

import Testing
import VaporTesting

@testable import APIServer

/// Signs in as the admin `username` and returns the session cookie. Creates
/// the account, with the password `testpassword`, on first use.
@discardableResult
func loginAsAdmin(_ username: String, on app: Application) async throws -> String {
    try await loginUser(username: username, password: "testpassword", role: "admin", on: app)
}

/// GETs `path` with the session `cookie` and returns the response body.
///
/// Records an issue at the caller's line when the response status is not
/// `status`, so a failure names the test and not this helper.
func getHTML(
    _ path: String,
    cookie: String,
    on app: Application,
    expecting status: HTTPStatus = .ok,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> String {
    let response = try await app.asyncSendRequest(.GET, path) { req in
        req.headers.add(name: .cookie, value: cookie)
    }
    #expect(response.status == status, "GET \(path)", sourceLocation: sourceLocation)
    return response.body.string
}
