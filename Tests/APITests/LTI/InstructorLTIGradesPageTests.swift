// Tests/APITests/LTI/InstructorLTIGradesPageTests.swift
//
// The instructor LMS grades page (docs/lti-1-3.md "Grades through AGS"): it
// renders for linked and unlinked courses, only an instructor switches the
// transport and only once the LMS sent a grade service URL, and "Push all"
// queues every graded student.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct InstructorLTIGradesPageTests {
    static let lineItemsURL = "https://lms.example.edu/api/lti/courses/7/line_items"

    /// Links the shared test course to a registered platform.
    private func link(_ app: Application, gradeService: Bool = true, usesAGS: Bool = false) async throws -> APICourse {
        let platform = APILTIPlatform(
            issuer: "https://lms.example.edu", clientID: "client", deploymentIDs: ["d1"],
            authLoginURL: "https://lms.example.edu/auth", accessTokenURL: "https://lms.example.edu/token",
            jwksURL: "https://lms.example.edu/jwks", displayName: "Test LMS", enabled: true)
        try await platform.save(on: app.db)
        let course = try #require(
            try await APICourse.find(try await app.testCourseID(enrollmentMode: .auto), on: app.db))
        try await LTICourseBinding.bind(
            course, platformID: try platform.requireID(), contextID: "context-1", on: app.db)
        course.ltiLineItemsURL = gradeService ? Self.lineItemsURL : nil
        course.ltiGradesEnabled = usesAGS
        try await course.save(on: app.db)
        return course
    }

    private func get(
        _ app: Application, _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try check(try await getResponse(path, cookie: cookie, on: app))
    }

    private func post(
        _ app: Application, _ path: String, _ fields: [String: String], cookie: String,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        let (token, boundCookie) = try await csrfFields(for: "/instructor/lti-grades", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: check)
    }

    // MARK: - Page

    @Test func anUnlinkedCourseSaysSo() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            try await get(app, "/instructor/lti-grades", cookie: cookie) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("not linked to an LMS course"))
                #expect(!res.body.string.contains("/instructor/lti-grades/transport"))
            }
        }
    }

    @Test func aLinkedCourseOffersTheTransportChoice() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await link(app)
            try await get(app, "/instructor/lti-grades", cookie: cookie) { res in
                #expect(res.status == .ok)
                let html = res.body.string
                #expect(html.contains("linked to Test LMS"))
                #expect(html.contains("/instructor/lti-grades/transport"))
                #expect(!html.contains("/instructor/lti-grades/push-all"))
            }
        }
    }

    @Test func theLEARNPageLinksHereOnlyForALinkedCourse() async throws {
        try await withAssignmentRoutesApp { app in
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            let cookie = try await arLoginAsInstructor(on: app)
            try await get(app, "/instructor/brightspace", cookie: cookie) { res in
                #expect(!res.body.string.contains("/instructor/lti-grades"))
            }
            _ = try await link(app)
            try await get(app, "/instructor/brightspace", cookie: cookie) { res in
                #expect(res.body.string.contains("/instructor/lti-grades"))
            }
        }
    }

    @Test func theLEARNPageSaysWhenValenceIsOff() async throws {
        try await withAssignmentRoutesApp { app in
            app.brightSpaceAppCredentials = BrightSpaceAppCredentials(
                baseURL: "https://learn.test", appID: "a", appKey: "k", debounceSecs: 90)
            let cookie = try await arLoginAsInstructor(on: app)
            _ = try await link(app, usesAGS: true)
            try await get(app, "/instructor/brightspace", cookie: cookie) { res in
                let html = res.body.string
                #expect(html.contains("not the Valence sync"))
                #expect(!html.contains("/instructor/brightspace/sync-now"))
            }
        }
    }

    @Test func failedPushesAreCountedAndListed() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await link(app, usesAGS: true)
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "lti-failed-setup", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "lti-failed-setup", courseID: courseID, title: "Lab 1")
            let student = try await makeTestUser(on: app, username: "lti_failed")
            let row = APILTIGradeSync(
                userID: try student.requireID(), testSetupID: "lti-failed-setup", pendingSince: Date())
            row.pending = false
            row.error = LTIGradeSyncSweep.notLaunchedMessage
            try await row.save(on: app.db)

            try await get(app, "/instructor/lti-grades", cookie: cookie) { res in
                let html = res.body.string
                #expect(html.contains("1 failed"))
                #expect(html.contains("lti_failed"))
                #expect(html.contains(LTIGradeSyncSweep.notLaunchedMessage))
                #expect(html.contains("/instructor/lti-grades/push-all"))
                #expect(!html.contains("Showing the first"))
            }
        }
    }

    @Test func aStudentCannotOpenThePage() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsStudent(on: app)
            try await get(app, "/instructor/lti-grades", cookie: cookie) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    // MARK: - Transport

    @Test func anInstructorSwitchesTheCourseToAGS() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await link(app)
            try await post(app, "/instructor/lti-grades/transport", ["transport": "ags"], cookie: cookie) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/instructor/lti-grades?done=ags")
            }
            #expect(try await APICourse.find(course.id, on: app.db)?.usesLTIGrades == true)
            let audit = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.ltiGradeTransportChanged.rawValue)
                .count()
            #expect(audit == 1)

            try await post(app, "/instructor/lti-grades/transport", ["transport": "valence"], cookie: cookie) { _ in }
            #expect(try await APICourse.find(course.id, on: app.db)?.usesLTIGrades == false)
        }
    }

    @Test func agsNeedsTheGradeServiceURL() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await link(app, gradeService: false)
            try await post(app, "/instructor/lti-grades/transport", ["transport": "ags"], cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/instructor/lti-grades?error=service")
            }
            #expect(try await APICourse.find(course.id, on: app.db)?.usesLTIGrades == false)
        }
    }

    @Test func aTACannotSwitchTheTransport() async throws {
        try await withAssignmentRoutesApp { app in
            let course = try await link(app)
            let cookie = try await loginUser(username: "lti_ta", password: "testpassword", role: "student", on: app)
            let ta = try #require(try await APIUser.query(on: app.db).filter(\.$username == "lti_ta").first())
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db)
                    .filter(\.$userID == ta.requireID())
                    .filter(\.$course.$id == course.requireID())
                    .first())
            enrollment.role = .ta
            try await enrollment.save(on: app.db)

            try await post(app, "/instructor/lti-grades/transport", ["transport": "ags"], cookie: cookie) { res in
                #expect(res.status == .forbidden)
            }
            #expect(try await APICourse.find(course.id, on: app.db)?.usesLTIGrades == false)
        }
    }

    // MARK: - Push all

    @Test func pushAllQueuesEveryGradedStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let course = try await link(app, usesAGS: true)
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "lti-push-setup", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "lti-push-setup", courseID: courseID, title: "Lab 1")
            let student = try await makeTestUser(on: app, username: "lti_pusher")
            try await makeTestSubmission(
                on: app, id: "sub_lti_push", setupID: "lti-push-setup", userID: try student.requireID())

            try await post(app, "/instructor/lti-grades/push-all", [:], cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/instructor/lti-grades?done=push")
            }

            let rows = try await APILTIGradeSync.query(on: app.db).filter(\.$testSetupID == "lti-push-setup").all()
            #expect(rows.map(\.userID) == [try student.requireID()])
        }
    }
}
