// Tests/APITests/Admin/AdminCourseRouteRefusalTests.swift
//
// The refusals and state changes of the admin course routes that the larger
// AdminRoutesTests suite does not reach: a blank create form, a delete of a
// course that is not archived, the course-page unenroll, the bad ids and the
// unknown role of the per-course role form, the unknown user of the enroll
// form, the CSV bulk enroll, and the LEARN org-unit binding of the edit form.

import Core
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A `Client` stub for the LEARN org-unit lookup. Org unit 6606 answers with
/// its name; any other org unit answers 503; every other path answers 404, so
/// the version negotiation falls back to the pinned version.
private struct OrgUnitStubClient: Client {
    let eventLoop: any EventLoop

    func delegating(to eventLoop: any EventLoop) -> any Client {
        OrgUnitStubClient(eventLoop: eventLoop)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        let url = request.url.string
        guard url.contains("/orgstructure/") else {
            return eventLoop.makeSucceededFuture(ClientResponse(status: .notFound))
        }
        guard url.contains("/orgstructure/6606") else {
            return eventLoop.makeSucceededFuture(ClientResponse(status: .serviceUnavailable))
        }
        var headers = HTTPHeaders()
        headers.contentType = .json
        let body = ByteBuffer(string: #"{"Identifier":"6606","Name":"Health Data Science","Code":"HLTH"}"#)
        return eventLoop.makeSucceededFuture(ClientResponse(status: .ok, headers: headers, body: body))
    }
}

@Suite(.serialized) final class AdminCourseRouteRefusalTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-course-refusals")
    }

    /// POSTs a form with a CSRF token bound to `cookie`, and returns the
    /// status and the redirect target.
    private func post(
        _ path: String, fields: [String: String] = [:], cookie: String
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .ok
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(fields.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    private func enrollmentCount(userID: UUID, courseID: UUID) async throws -> Int {
        try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .count()
    }

    // MARK: - POST /admin/courses

    @Test func createCourseWithABlankNameRedirectsToTheFormAndCreatesNothing() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let before = try await APICourse.query(on: app.db).count()

            let response = try await post(
                "/admin/courses",
                fields: ["code": "BLANK101", "name": "   ", "termYear": "2027", "termSeason": "winter"],
                cookie: cookie)

            #expect(response.status == .seeOther)
            #expect(response.location == "/admin/courses/new?error=\(CourseFormError.fields.rawValue)")
            #expect(try await APICourse.query(on: app.db).count() == before)
        }
    }

    // MARK: - POST /admin/courses/:courseID/delete

    @Test func deleteOfAnActiveCourseIsRefusedAndTheCourseStays() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "LIVE101", name: "Still Running")
            let courseID = try course.requireID()

            let response = try await post("/admin/courses/\(courseID.uuidString)/delete", cookie: cookie)

            #expect(response.status == .seeOther)
            let location = try #require(response.location)
            #expect(location.hasPrefix("/admin/retention"))
            #expect(location.contains("error="))
            #expect(try await APICourse.find(courseID, on: app.db) != nil)
        }
    }

    // MARK: - POST /admin/courses/:courseID/unenroll/:userID

    @Test func courseUnenrollRemovesTheEnrollmentAndReturnsToTheCourse() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let student = try await makeTestUser(on: app, username: "course_unenroll_student")
            let userID = try student.requireID()
            let course = try await makeTestCourse(on: app, code: "UNENR101")
            let courseID = try course.requireID()
            try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)

            let response = try await post(
                "/admin/courses/\(courseID.uuidString)/unenroll/\(userID.uuidString)", cookie: cookie)

            #expect(response.status == .seeOther)
            #expect(response.location == "/admin/courses/\(courseID.uuidString)")
            #expect(try await enrollmentCount(userID: userID, courseID: courseID) == 0)
        }
    }

    @Test func courseUnenrollWithAMalformedUserIDIsABadRequest() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "UNENR102")
            let courseID = try course.requireID()

            let response = try await post(
                "/admin/courses/\(courseID.uuidString)/unenroll/not-a-uuid", cookie: cookie)

            #expect(response.status == .badRequest)
        }
    }

    @Test func aStudentIsRefusedTheCourseUnenrollAndTheEnrollmentStays() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsStudent("course_unenroll_intruder", on: app)
            let student = try await makeTestUser(on: app, username: "course_unenroll_victim")
            let userID = try student.requireID()
            let course = try await makeTestCourse(on: app, code: "UNENR103")
            let courseID = try course.requireID()
            try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)

            let response = try await post(
                "/admin/courses/\(courseID.uuidString)/unenroll/\(userID.uuidString)", cookie: cookie)

            #expect(response.status == .forbidden)
            #expect(try await enrollmentCount(userID: userID, courseID: courseID) == 1)
        }
    }

    // MARK: - POST /admin/courses/:courseID/role/:userID

    @Test func setRoleWithAMalformedCourseIDIsABadRequest() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let response = try await post(
                "/admin/courses/not-a-uuid/role/\(UUID().uuidString)", fields: ["role": "ta"], cookie: cookie)
            #expect(response.status == .badRequest)
        }
    }

    @Test func setRoleWithAnUnknownRoleIsABadRequestAndTheRoleStays() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let student = try await makeTestUser(on: app, username: "role_refusal_student")
            let userID = try student.requireID()
            let course = try await makeTestCourse(on: app, code: "ROLEREF1")
            let courseID = try course.requireID()
            try await makeTestEnrollment(on: app, userID: userID, courseID: courseID)

            let response = try await post(
                "/admin/courses/\(courseID.uuidString)/role/\(userID.uuidString)",
                fields: ["role": "dean"], cookie: cookie)

            #expect(response.status == .badRequest)
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == userID).filter(\.$course.$id == courseID).first())
            #expect(enrollment.role == .student)
        }
    }

    @Test func setRoleForAUserWhoIsNotEnrolledIsNotFound() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let outsider = try await makeTestUser(on: app, username: "role_refusal_outsider")
            let userID = try outsider.requireID()
            let course = try await makeTestCourse(on: app, code: "ROLEREF2")
            let courseID = try course.requireID()

            let response = try await post(
                "/admin/courses/\(courseID.uuidString)/role/\(userID.uuidString)",
                fields: ["role": "ta"], cookie: cookie)

            #expect(response.status == .notFound)
            #expect(try await enrollmentCount(userID: userID, courseID: courseID) == 0)
        }
    }

    // MARK: - POST /admin/users/:userID/enroll and /unenroll/:courseID

    @Test func enrollOfAnUnknownUserIsNotFound() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "ENRREF1")
            let courseID = try course.requireID()

            let response = try await post(
                "/admin/users/\(UUID().uuidString)/enroll", fields: ["courseID": courseID.uuidString],
                cookie: cookie)

            #expect(response.status == .notFound)
            let count = try await APICourseEnrollment.query(on: app.db).filter(\.$course.$id == courseID).count()
            #expect(count == 0)
        }
    }

    @Test func userUnenrollWithAMalformedCourseIDIsABadRequest() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let student = try await makeTestUser(on: app, username: "user_unenroll_student")
            let userID = try student.requireID()

            let response = try await post(
                "/admin/users/\(userID.uuidString)/unenroll/not-a-uuid", cookie: cookie)

            #expect(response.status == .badRequest)
        }
    }

    // MARK: - POST /admin/courses/:courseID/enroll-csv

    /// POSTs `csv` as the multipart `file` field, and returns the status and
    /// the body.
    private func postCSV(
        _ csv: String, courseID: String, cookie: String
    ) async throws -> (status: HTTPStatus, body: String) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .ok
        var html = ""
        try await app.asyncTest(
            .POST, "/admin/courses/\(courseID)/enroll-csv",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                let boundary = "----AdminCSVBoundary"
                let part =
                    "--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"roster.csv\"\r\n"
                    + "Content-Type: text/csv\r\n\r\n\(csv)\r\n--\(boundary)\r\n"
                    + "Content-Disposition: form-data; name=\"_csrf\"\r\n\r\n\(token)\r\n--\(boundary)--\r\n"
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": boundary])
                req.body = ByteBuffer(string: part)
            },
            afterResponse: { res in
                status = res.status
                html = res.body.string
            })
        return (status, html)
    }

    @Test func csvEnrollEnrollsKnownUsersAndPreEnrollsTheRest() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let known = try await makeTestUser(on: app, username: "csv_admin_known")
            let knownID = try known.requireID()
            let course = try await makeTestCourse(on: app, code: "CSVADM1", name: "Roster Course")
            let courseID = try course.requireID()

            let response = try await postCSV(
                "csv_admin_known\ncsv_admin_newcomer\n", courseID: courseID.uuidString, cookie: cookie)

            #expect(response.status == .ok)
            #expect(response.body.contains("CSVADM1"))
            #expect(response.body.contains("/admin/courses/\(courseID.uuidString)"))
            #expect(response.body.contains("<dt>Enrolled (existing accounts)</dt><dd>1</dd>"))
            #expect(response.body.contains("<dt>Pre-enrolled</dt><dd>1</dd>"))
            #expect(try await enrollmentCount(userID: knownID, courseID: courseID) == 1)
        }
    }

    @Test func csvEnrollIntoAnArchivedCourseIsABadRequestAndEnrollsNobody() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let known = try await makeTestUser(on: app, username: "csv_admin_archived")
            let knownID = try known.requireID()
            let course = try await makeTestCourse(on: app, code: "CSVADM2", archived: true)
            let courseID = try course.requireID()

            let response = try await postCSV(
                "csv_admin_archived\n", courseID: courseID.uuidString, cookie: cookie)

            #expect(response.status == .badRequest)
            #expect(try await enrollmentCount(userID: knownID, courseID: courseID) == 0)
        }
    }

    @Test func csvEnrollIntoAnUnknownCourseIsABadRequest() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let response = try await postCSV("anyone\n", courseID: UUID().uuidString, cookie: cookie)
            #expect(response.status == .badRequest)
        }
    }

    // MARK: - POST /admin/courses/:courseID/edit (LEARN org unit)

    private func useLearnStub() {
        let credentials = BrightSpaceAppCredentials(
            baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
        app.brightSpaceAppCredentials = credentials
        app.brightSpaceClient = BrightSpaceAPIClient(
            config: BrightSpaceSyncConfig(app: credentials, userID: "svc", userKey: "svc-key"))
        app.clients.use { app in OrgUnitStubClient(eventLoop: app.eventLoopGroup.next()) }
    }

    private func editOrgUnit(_ orgUnit: String, course: APICourse, cookie: String) async throws -> APICourse {
        let courseID = try course.requireID()
        let response = try await post(
            "/admin/courses/\(courseID.uuidString)/edit",
            fields: ["code": course.code, "name": course.name, "brightspaceOrgUnitID": orgUnit],
            cookie: cookie)
        #expect(response.status == .seeOther)
        #expect(response.location == "/admin/courses/\(courseID.uuidString)")
        return try #require(try await APICourse.find(courseID, on: app.db))
    }

    @Test func editBindsAVerifiedOrgUnitAndCachesItsName() async throws {
        try await withApp(app) { _ in
            useLearnStub()
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "ORGU101")

            let saved = try await editOrgUnit(" 6606 ", course: course, cookie: cookie)

            #expect(saved.brightspaceOrgUnitID == "6606")
            #expect(saved.brightspaceOrgUnitName == "Health Data Science")
        }
    }

    @Test func editKeepsAnOrgUnitThatCannotBeVerifiedWithoutAName() async throws {
        try await withApp(app) { _ in
            useLearnStub()
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "ORGU102")
            course.brightspaceOrgUnitName = "Stale Name"
            try await course.save(on: app.db)

            let saved = try await editOrgUnit("7777", course: course, cookie: cookie)

            #expect(saved.brightspaceOrgUnitID == "7777")
            #expect(saved.brightspaceOrgUnitName == nil)
        }
    }

    @Test func editWithABlankOrgUnitClearsTheBinding() async throws {
        try await withApp(app) { _ in
            useLearnStub()
            let cookie = try await loginAsAdmin("course_refusal_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "ORGU103")
            course.brightspaceOrgUnitID = "6606"
            course.brightspaceOrgUnitName = "Health Data Science"
            try await course.save(on: app.db)

            let saved = try await editOrgUnit("   ", course: course, cookie: cookie)

            #expect(saved.brightspaceOrgUnitID == nil)
            #expect(saved.brightspaceOrgUnitName == nil)
        }
    }
}
