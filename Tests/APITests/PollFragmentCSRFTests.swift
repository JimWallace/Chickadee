// Tests/APITests/PollFragmentCSRFTests.swift
//
// The People poll renders rows that carry CSRF tokens, and every token has a
// fresh random salt. The ETag leaves the token out, so a poll of unchanged rows
// answers 304 instead of repainting the table every five seconds.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct PollFragmentETagTokenTests {

    @Test func theTokenDoesNotChangeTheETag() {
        let first = Response.weakETag(
            for: #"<tr><input name="_csrf" value="aa-11"></tr>"#, ignoring: "aa-11")
        let second = Response.weakETag(
            for: #"<tr><input name="_csrf" value="bb-22"></tr>"#, ignoring: "bb-22")
        #expect(first == second)
    }

    @Test func changedRowsStillChangeTheETag() {
        let first = Response.weakETag(for: "<tr>a aa-11</tr>", ignoring: "aa-11")
        let second = Response.weakETag(for: "<tr>b bb-22</tr>", ignoring: "bb-22")
        #expect(first != second)
    }
}

@Suite(.serialized) final class PollFragmentCSRFTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-poll-csrf")
    }

    /// The status and ETag of one People poll.
    private func poll(cookie: String, ifNoneMatch: String? = nil) async throws -> (HTTPStatus, String?) {
        var result: (HTTPStatus, String?) = (.ok, nil)
        try await app.asyncTest(
            .GET, "/admin/users-data?fragment=rows",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: cookie)
                if let ifNoneMatch { req.headers.add(name: .ifNoneMatch, value: ifNoneMatch) }
            },
            afterResponse: { res in result = (res.status, res.headers.first(name: .eTag)) })
        return result
    }

    @Test func anUnchangedPeoplePollAnswers304() async throws {
        try await withApp(app) { app in
            // A second account gives the rows a delete form, and so a token.
            _ = try await loginUser(username: "poll_student", password: "pw", role: "student", on: app)
            let cookie = try await loginAsAdmin("poll_admin", on: app)
            let html = try await getHTML("/admin/users-data?fragment=rows", cookie: cookie, on: app)
            #expect(html.contains(#"name="_csrf""#))
            let (status, etag) = try await poll(cookie: cookie)
            #expect(status == .ok)
            let tag = try #require(etag)
            let (second, _) = try await poll(cookie: cookie, ifNoneMatch: tag)
            #expect(second == .notModified)
        }
    }
}

/// The Students poll: a pending student's row carries a register form, and so
/// a token.
@Suite(.serialized) struct StudentsPollETagTests {

    @Test func anUnchangedStudentsPollAnswers304() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await APIPreEnrollment(courseID: courseID, username: "poll_pending").save(on: app.db)
            let path = "/instructor/students-data?fragment=rows"
            let html = try await getHTML(path, cookie: cookie, on: app)
            #expect(html.contains(#"name="_csrf""#))

            var etag: String?
            try await app.asyncTest(
                .GET, path, beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in etag = res.headers.first(name: .eTag) })
            let tag = try #require(etag)
            var status: HTTPStatus = .ok
            try await app.asyncTest(
                .GET, path,
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    req.headers.add(name: .ifNoneMatch, value: tag)
                },
                afterResponse: { res in status = res.status })
            #expect(status == .notModified)
        }
    }
}
