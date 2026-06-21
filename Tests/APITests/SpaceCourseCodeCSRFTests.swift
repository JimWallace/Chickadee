// Tests/APITests/SpaceCourseCodeCSRFTests.swift
//
// Regression: a course code with a space (e.g. "HLTH 230", URL-encoded as
// /HLTH%20230/...) must round-trip through the CSRF-protected extension-save
// flow exactly like a space-free code. Production has such courses, and this
// pins that the percent-encoded path segment does not break route matching,
// course resolution, or CSRF token validation — so a "CSRF error" reported
// against such a course is NOT caused by the space in the path.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct SpaceCourseCodeCSRFTests {

    @Test func extensionSaveWorksForSpacedCourseCode() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)

            // Course code with a space, like "HLTH 230".
            let course = APICourse(code: "HLTH 230", name: "Health 230", enrollmentMode: .open)
            try await course.save(on: app.db)
            let courseID = try course.requireID()

            let student = try await arInsertStudent(username: "spaced_student", on: app)
            try await APICourseEnrollment(userID: try student.requireID(), courseID: courseID)
                .save(on: app.db)

            let manifest = """
                {"schemaVersion":1,"requiredFiles":[],"testSuites":[{"tier":"public","script":"test.sh"}],"timeLimitSeconds":10,"makefile":null}
                """
            let setup = APITestSetup(
                id: "spaced_setup", manifest: manifest,
                zipPath: app.testSetupsDirectory + "spaced_setup.zip", courseID: courseID)
            try await setup.save(on: app.db)

            let assignment = APIAssignment(
                testSetupID: "spaced_setup", title: "Spaced", isOpen: true, courseID: courseID)
            try await assignment.save(on: app.db)

            let token = try student.requireURLToken()
            let pagePath = "/HLTH%20230/students/\(token)/submissions"

            var pageToken = ""
            var pageCookie = cookie
            try await app.asyncTest(
                .GET, pagePath,
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok, "Submissions page must render (got \(res.status))")
                    if let c = res.headers.first(name: .setCookie) { pageCookie = c }
                    pageToken = extractCSRFToken(from: res.body.string)
                }
            )
            #expect(pageToken.isEmpty == false, "Extension form must carry a CSRF token")

            let fmt = DateFormatter()
            fmt.locale = Locale(identifier: "en_US_POSIX")
            fmt.timeZone = TimeZone(identifier: "America/Toronto")
            fmt.dateFormat = "yyyy-MM-dd'T'HH:mm"

            try await app.asyncTest(
                .POST,
                "/HLTH%20230/students/\(token)/assignments/\(assignment.publicID)/extension",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: pageCookie)
                    try req.content.encode(
                        [
                            "_csrf": pageToken,
                            "extendedDueAt": fmt.string(from: Date().addingTimeInterval(86_400)),
                            "note": "conf",
                        ],
                        as: .urlEncodedForm
                    )
                },
                afterResponse: { res in
                    #expect(
                        res.status != .forbidden,
                        "Spaced-course extension save must not 403 (got \(res.status))"
                    )
                    #expect(res.status == .seeOther)
                }
            )
        }
    }
}
