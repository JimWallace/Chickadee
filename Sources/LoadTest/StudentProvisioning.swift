// LoadTest/StudentProvisioning.swift
//
// Gives each simulated student a signed-in session in the activity's course,
// through the same pages a student uses: register (or sign in, when the
// account exists from an earlier run), then enrol in the course from
// `/enroll`. It needs local accounts, so it works only where `AUTH_MODE`
// allows them, and the course must be open for self-enrolment.

import Foundation
import NIOHTTP1

enum ProvisioningError: Error, Equatable, CustomStringConvertible {
    case noCSRFToken(page: String)
    case registrationRefused(username: String, location: String)
    case signInRefused(username: String, status: Int, location: String)
    case enrollmentRefused(username: String, location: String)
    case rateLimited(username: String)

    var description: String {
        switch self {
        case .noCSRFToken(let page):
            return "\(page) carried no CSRF token. Is the server in AUTH_MODE=local or dual?"
        case .registrationRefused(let username, let location):
            return "The server refused to register \(username) (redirect to \(location))."
        case .signInRefused(let username, let status, let location):
            return "\(username) could not sign in: HTTP \(status), redirect to \(location). "
                + "Use the same --student-password as the run that created the account."
        case .enrollmentRefused(let username, let location):
            return "\(username) could not enrol (redirect to \(location)). "
                + "The course must be open for self-enrolment, and --course-id must be its ID."
        case .rateLimited(let username):
            return "The sign-in rate limit stopped \(username). Run the server with "
                + "LOGIN_RATE_LIMIT_ENABLED=false for a load test, or provision fewer students per minute."
        }
    }
}

struct StudentProvisioning: Sendable {
    let exchange: HTTPExchange
    let target: LoadTarget
    let courseID: String
    let password: String

    /// Waits this long and tries again when the per-IP limit answers 429.
    static let rateLimitRetries = 3

    func session(for username: String) async throws -> StudentSession {
        var jar = CookieJar()
        let registered = try await submitAccountForm(path: "/register", username: username, jar: &jar)
        let location = registered.header("Location") ?? ""
        if location.contains("error=taken") {
            try await signIn(username: username, jar: &jar)
        } else if location.contains("error=") || registered.status >= 400 {
            throw ProvisioningError.registrationRefused(username: username, location: location)
        }
        try await enroll(username: username, jar: &jar)
        return StudentSession(username: username, cookieHeader: jar.header ?? "")
    }

    private func signIn(username: String, jar: inout CookieJar) async throws {
        let reply = try await submitAccountForm(path: "/login", username: username, jar: &jar)
        let location = reply.header("Location") ?? ""
        guard (300..<400).contains(reply.status), !location.contains("/login") else {
            throw ProvisioningError.signInRefused(username: username, status: reply.status, location: location)
        }
    }

    /// GETs the form for its CSRF token, then POSTs the username and
    /// password, the way the browser submits `/register` and `/login`.
    private func submitAccountForm(path: String, username: String, jar: inout CookieJar) async throws -> HTTPReply {
        for attempt in 0...Self.rateLimitRetries {
            let form = try await get(path, jar: &jar)
            guard let token = HTMLScrape.csrfToken(in: form.text) else {
                throw ProvisioningError.noCSRFToken(page: path)
            }
            let reply = try await postForm(
                path, fields: [("username", username), ("password", password), ("_csrf", token)], jar: &jar)
            guard reply.status == 429 else { return reply }
            guard attempt < Self.rateLimitRetries else { break }
            let wait = Int(reply.header("Retry-After") ?? "") ?? 10
            try await Task.sleep(for: .seconds(min(max(wait, 1), 60)))
        }
        throw ProvisioningError.rateLimited(username: username)
    }

    private func enroll(username: String, jar: inout CookieJar) async throws {
        let page = try await get("/enroll", jar: &jar)
        guard let token = HTMLScrape.csrfToken(in: page.text) else {
            throw ProvisioningError.noCSRFToken(page: "/enroll")
        }
        let reply = try await postForm(
            "/enroll", fields: [("courseIDs[]", courseID), ("_csrf", token)], jar: &jar)
        let location = reply.header("Location") ?? ""
        guard (300..<400).contains(reply.status), !location.contains("/enroll") else {
            throw ProvisioningError.enrollmentRefused(username: username, location: location)
        }
    }

    private func get(_ path: String, jar: inout CookieJar) async throws -> HTTPReply {
        var headers: HTTPHeaders = ["Accept": "text/html"]
        if let cookie = jar.header { headers.add(name: "Cookie", value: cookie) }
        let reply = try await exchange.send(.GET, target.url(forPath: path), headers: headers, keep: 1 << 20)
        jar.absorb(reply.headers)
        return reply
    }

    private func postForm(_ path: String, fields: [(String, String)], jar: inout CookieJar) async throws -> HTTPReply {
        var headers: HTTPHeaders = ["Content-Type": "application/x-www-form-urlencoded", "Accept": "text/html"]
        if let cookie = jar.header { headers.add(name: "Cookie", value: cookie) }
        let body = Data(Self.formEncode(fields).utf8)
        let reply = try await exchange.send(
            .POST, target.url(forPath: path), headers: headers, body: body, keep: 1 << 16)
        jar.absorb(reply.headers)
        return reply
    }

    /// `application/x-www-form-urlencoded`, with the strict character set.
    static func formEncode(_ fields: [(String, String)]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        func encode(_ value: String) -> String {
            (value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)
        }
        return fields.map { "\(encode($0.0))=\(encode($0.1))" }.joined(separator: "&")
    }
}
