// Tests/APITests/Admin/AdminUserEnrollErrorTests.swift
//
// A refused enrollment on the admin user page redirects back with an error
// code. The page must show the error, and must show only the fixed message
// for a known code, never text taken from the query.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct AdminUserEnrollErrorTests {

    @Test func anArchivedCourseIsRefusedAndThePageSaysSo() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let admin = try await loginUser(
                username: "enroll_error_admin", password: "pw", role: "admin", on: app)
            let subjectID = try await makeTestUser(on: app, username: "enroll_error_subject").requireID()
            let archived = try await makeTestCourse(on: app, code: "OLD101", archived: true).requireID()
            let page = "/admin/users/\(subjectID.uuidString)"
            let (token, cookie) = try await csrfFields(for: page, cookie: admin, on: app)

            var location = ""
            try await app.asyncTest(
                .POST, "\(page)/enroll",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                    try req.content.encode(
                        ["courseID": archived.uuidString, "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    location = res.headers.first(name: .location) ?? ""
                })
            #expect(location == "\(page)?error=invalid_course")

            let body = try await getHTML(location, cookie: cookie, on: app)
            #expect(
                body.contains(
                    "<div class=\"flash flash-error\" role=\"alert\">That course does not exist or is archived.</div>"))
        }
    }

    @Test func anUnknownErrorCodeShowsNothing() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let admin = try await loginUser(
                username: "enroll_error_admin2", password: "pw", role: "admin", on: app)
            let subjectID = try await makeTestUser(on: app, username: "enroll_error_subject2").requireID()
            let body = try await getHTML(
                "/admin/users/\(subjectID.uuidString)?error=%3Cb%3Einjected", cookie: admin, on: app)
            #expect(body.contains("flash-error") == false)
            #expect(body.contains("injected") == false)
        }
    }
}
