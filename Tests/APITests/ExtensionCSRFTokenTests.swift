// Tests/APITests/ExtensionCSRFTokenTests.swift
//
// Regression coverage for the "CSRF error when saving an extension" report.
//
// The extension endpoints are correctly CSRF-protected, and the token a page
// embeds at render time stays valid for the life of the session — so the
// happy path works even from a long-open page. The narrow failure mode is a
// submit from a page whose *session was replaced* (e.g. idle-timeout then
// re-login), which yields a stale token.
//
// This pins the happy path: the real course-student-submissions page's own
// extension-form token passes CSRF (scraped from the actual rendered page,
// closing the gap where the older tests pulled a token from /instructor).
// The recoverable error page for the stale-token case is covered against the
// production error middleware in SecurityAndHealthTests
// (`leafErrorMiddlewareRendersRecoverableMessageForCSRFFailures`); the test
// harness here doesn't install LeafErrorMiddleware.
//
// `extensionSaveWithStreamedBodyPassesCSRF` pins the *actual* root cause of
// the production report: Vapor dispatches a request whose body did not arrive
// in the same channel read as the head (split TCP reads, chunked encoding) as
// a *streaming* body, and the CSRF token retrieval used to read `_csrf` with
// a synchronous `content.get` — nil for a streaming body — so the request
// 403'd "No CSRF token provided." even though the field was on the wire.
// XCTVapor's in-memory transport always delivers pre-collected bodies, so
// that path needs a real socket: the test boots the server on a loopback
// port and POSTs the extension form with `Transfer-Encoding: chunked`, which
// the decoder deterministically dispatches as a stream.

import Core
import Fluent
import Foundation
import Testing
import XCTVapor

@testable import APIServer

#if canImport(Glibc)
import Glibc
#endif

@Suite struct ExtensionCSRFTokenTests {

    /// Seeds an instructor session, an enrolled student, and a published
    /// assignment; returns the login cookie, the student, and the assignment.
    private func seed(
        on app: Application
    ) async throws -> (cookie: String, student: APIUser, assignment: APIAssignment) {
        let cookie = try await arLoginAsInstructor(on: app)
        let student = try await arInsertStudent(username: "csrf_ext_student", on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        try await arInsertSetup(id: "csrf_ext_setup", on: app)
        let assignment = try await arInsertAssignment(
            testSetupID: "csrf_ext_setup",
            title: "CSRF Ext",
            isOpen: true,
            dueAt: Date().addingTimeInterval(-3_600),
            on: app
        )
        return (cookie, student, assignment)
    }

    private func localInput(_ date: Date) -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(identifier: "America/Toronto")
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"
        return fmt.string(from: date)
    }

    // MARK: - Happy path: the real page's own token works

    @Test func extensionSaveUsingRealPageToken() async throws {
        try await withAssignmentRoutesApp { app in
            let (cookie, student, assignment) = try await seed(on: app)
            let token = try student.requireURLToken()

            var pageToken = ""
            var pageCookie = cookie
            try await app.asyncTest(
                .GET, "/TEST101/students/\(token)/submissions",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    if let c = res.headers.first(name: .setCookie) { pageCookie = c }
                    pageToken = extractCSRFToken(from: res.body.string)
                }
            )
            #expect(pageToken.isEmpty == false, "Extension form must carry a CSRF token")

            try await app.asyncTest(
                .POST,
                "/TEST101/students/\(token)/assignments/\(assignment.publicID)/extension",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: pageCookie)
                    try req.content.encode(
                        [
                            "_csrf": pageToken,
                            "extendedDueAt": localInput(Date().addingTimeInterval(86_400)),
                            "note": "x",
                        ],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther, "Real-page token must pass CSRF (got \(res.status))")
                }
            )
        }
    }

    // MARK: - Streaming body: the production failure mode

    /// A form POST whose body Vapor dispatches as a *stream* (here forced
    /// deterministically with chunked transfer-encoding over a real socket)
    /// must still pass CSRF. Before the body-collect fix in
    /// `chickadeeCSRFTokenRetrieval` this 403'd "No CSRF token provided."
    @Test func extensionSaveWithStreamedBodyPassesCSRF() async throws {
        try await withAssignmentRoutesApp { app in
            let (cookie, student, assignment) = try await seed(on: app)
            let token = try student.requireURLToken()

            var pageToken = ""
            var pageCookie = cookie
            try await app.asyncTest(
                .GET, "/TEST101/students/\(token)/submissions",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    if let c = res.headers.first(name: .setCookie) { pageCookie = c }
                    pageToken = extractCSRFToken(from: res.body.string)
                }
            )
            #expect(pageToken.isEmpty == false, "Extension form must carry a CSRF token")
            // Set-Cookie → Cookie: keep just the `name=value` pair.
            let cookiePair = pageCookie.components(separatedBy: ";")[0]

            let due = localInput(Date().addingTimeInterval(86_400))
                .replacingOccurrences(of: ":", with: "%3A")
            let formBody = "_csrf=\(pageToken)&extendedDueAt=\(due)&note=streamed"
            let path = "/TEST101/students/\(token)/assignments/\(assignment.publicID)/extension"
            let request =
                "POST \(path) HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\n"
                + "Connection: close\r\n"
                + "Cookie: \(cookiePair)\r\n"
                + "Content-Type: application/x-www-form-urlencoded\r\n"
                + "Transfer-Encoding: chunked\r\n"
                + "\r\n"
                + String(formBody.utf8.count, radix: 16) + "\r\n"
                + formBody + "\r\n"
                + "0\r\n\r\n"

            // The sync `shutdown()` is `noasync`, and `defer` can't await —
            // shut down explicitly on both exits instead.
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let response: String
            do {
                let port = try #require(app.http.server.shared.localAddress?.port)
                response = try rawLoopbackHTTPExchange(port: port, request: request)
            } catch {
                await app.server.shutdown()
                throw error
            }
            await app.server.shutdown()
            let statusLine = response.components(separatedBy: "\r\n")[0]
            #expect(
                statusLine.contains("303"),
                "Streamed-body extension save must pass CSRF (got '\(statusLine)')"
            )

            let saved = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$assignmentID == assignment.requireID())
                .filter(\.$userID == student.requireID())
                .first()
            #expect(saved != nil, "Extension row must be persisted from the streamed POST")
        }
    }
}

/// Sends raw bytes to 127.0.0.1:`port` and returns the full response read
/// until the server closes the connection (`Connection: close` request).
/// Plain blocking POSIX sockets — the point is to exercise the real server
/// pipeline, which XCTVapor's in-memory transport bypasses.
private func rawLoopbackHTTPExchange(port: Int, request: String) throws -> String {
    #if os(Linux)
    let sockStream = Int32(SOCK_STREAM.rawValue)
    #else
    let sockStream = SOCK_STREAM
    #endif
    let fd = socket(AF_INET, sockStream, 0)
    try #require(fd >= 0, "socket() failed: errno \(errno)")
    defer { close(fd) }

    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = in_port_t(port).bigEndian
    try #require(
        inet_pton(AF_INET, "127.0.0.1", &addr.sin_addr) == 1,
        "inet_pton failed"
    )
    let connectResult = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
            connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    try #require(connectResult == 0, "connect() failed: errno \(errno)")

    let bytes = Array(request.utf8)
    var sent = 0
    while sent < bytes.count {
        let n = bytes.withUnsafeBytes { raw in
            send(fd, raw.baseAddress.map { $0 + sent }, bytes.count - sent, 0)
        }
        try #require(n > 0, "send() failed: errno \(errno)")
        sent += n
    }

    var response: [UInt8] = []
    var chunk = [UInt8](repeating: 0, count: 4096)
    while true {
        let n = chunk.withUnsafeMutableBytes { raw in
            recv(fd, raw.baseAddress, raw.count, 0)
        }
        if n <= 0 { break }
        response.append(contentsOf: chunk[0..<n])
    }
    return try #require(
        String(bytes: response, encoding: .utf8),
        "Response was not valid UTF-8"
    )
}
