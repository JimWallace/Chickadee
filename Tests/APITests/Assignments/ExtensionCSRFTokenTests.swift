// Tests/APITests/Assignments/ExtensionCSRFTokenTests.swift
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
// (`errorPageMiddlewareRendersRecoverableMessageForCSRFFailures`); the test
// harness here doesn't install ErrorPageMiddleware.
//
// `extensionSaveWithStreamedBodyPassesCSRF` pins the *actual* root cause of
// the production report: Vapor dispatches a request whose body did not arrive
// in the same channel read as the head (split TCP reads, chunked encoding) as
// a *streaming* body, and the CSRF token retrieval used to read `_csrf` with
// a synchronous `content.get` — nil for a streaming body — so the request
// 403'd "No CSRF token provided." even though the field was on the wire.
// VaporTesting's in-memory transport always delivers pre-collected bodies, so
// that path needs a real socket: the test boots the server on a loopback
// port and POSTs the extension form with `Transfer-Encoding: chunked`, which
// the decoder deterministically dispatches as a stream.

import AsyncHTTPClient
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct ExtensionCSRFTokenTests {

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

            // The sync `shutdown()` is `noasync`, and `defer` can't await —
            // shut down explicitly on both exits instead.
            try await app.server.start(address: .hostname("127.0.0.1", port: 0))
            let status: HTTPResponseStatus
            do {
                let port = try #require(app.http.server.shared.localAddress?.port)
                status = try await postChunkedForm(
                    to: "http://127.0.0.1:\(port)\(path)", cookie: cookiePair, body: formBody)
            } catch {
                await app.server.shutdown()
                throw error
            }
            await app.server.shutdown()
            #expect(status == .seeOther, "Streamed-body extension save must pass CSRF (got \(status))")

            let saved = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$assignmentID == assignment.requireID())
                .filter(\.$userID == student.requireID())
                .first()
            #expect(saved != nil, "Extension row must be persisted from the streamed POST")
        }
    }
}

/// POSTs `body` as a form to the real server and returns the status. The
/// point is to exercise the real server pipeline, which VaporTesting's
/// in-memory transport bypasses. A body of unknown length makes
/// AsyncHTTPClient send it chunked, which is what makes Vapor stream it. The
/// 303 is the answer, so redirects are not followed.
private func postChunkedForm(to url: String, cookie: String, body: String) async throws -> HTTPResponseStatus {
    // Sixty seconds stays under the suite's two-minute limit and above a
    // loaded CI runner's answer time (#2361).
    let client = HTTPClient(
        configuration: .init(redirectConfiguration: .disallow, timeout: .init(read: .seconds(60))))
    var request = HTTPClientRequest(url: url)
    request.method = .POST
    request.headers.add(name: "Cookie", value: cookie)
    request.headers.add(name: "Content-Type", value: "application/x-www-form-urlencoded")
    let chunks = AsyncStream<ByteBuffer> { continuation in
        continuation.yield(ByteBuffer(string: body))
        continuation.finish()
    }
    request.body = .stream(chunks, length: .unknown)

    let outcome: Result<HTTPResponseStatus, any Error>
    do {
        outcome = .success(try await client.execute(request, timeout: .seconds(60)).status)
    } catch {
        outcome = .failure(error)
    }
    try? await client.shutdown()
    return try outcome.get()
}
