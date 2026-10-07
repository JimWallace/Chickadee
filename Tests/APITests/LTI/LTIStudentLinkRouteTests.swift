// Tests/APITests/LTI/LTIStudentLinkRouteTests.swift
//
// "Link students" on the LMS grades page (docs/lti-1-3.md "Roster through
// NRPS"): an instructor links the course's students to their LMS subjects by
// student number, so the AGS sweep can send the grades of a student who never
// opened Chickadee from the LMS.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LTIStudentLinkRouteTests {
    struct Linked {
        let courseID: UUID
        let platformID: UUID
    }

    /// Links the shared test course to a platform whose NRPS the stand-in LMS
    /// answers, with grades going through AGS.
    private func link(_ app: Application, lms: LTITestGradeService, keyDirectory: URL) async throws -> Linked {
        app.ltiServiceClient = await lms.client
        app.ltiToolKeyFilePath = keyDirectory.appendingPathComponent(".lti-tool-key").path
        let platform = APILTIPlatform(
            issuer: LTITestPlatform.issuer, clientID: LTITestPlatform.clientID,
            deploymentIDs: [LTITestPlatform.deploymentID], authLoginURL: LTITestPlatform.authLoginURL,
            accessTokenURL: LTITestGradeService.tokenURL, jwksURL: "https://lms.example.edu/jwks",
            displayName: "Test LMS", enabled: true)
        try await platform.save(on: app.db)
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let course = try #require(try await APICourse.find(courseID, on: app.db))
        try await LTICourseBinding.bind(
            course, platformID: try platform.requireID(), contextID: "context-1", on: app.db)
        course.ltiMembershipsURL = LTITestGradeService.membershipsURL
        course.ltiLineItemsURL = LTITestGradeService.lineItemsURL
        course.ltiGradesEnabled = true
        try await course.save(on: app.db)
        return Linked(courseID: courseID, platformID: try platform.requireID())
    }

    private func enrol(
        _ app: Application, _ username: String, studentID: String?, courseID: UUID, role: String = "student"
    ) async throws -> UUID {
        let user = try await makeTestUser(on: app, username: username, role: role)
        user.studentID = studentID
        try await user.save(on: app.db)
        let userID = try user.requireID()
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: .student).save(on: app.db)
        return userID
    }

    private func postLink(
        _ app: Application, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        let (token, boundCookie) = try await csrfFields(for: "/instructor/lti-grades", cookie: cookie, on: app)
        try await app.asyncTest(
            .POST, "/instructor/lti-grades/link-students",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(["_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: check)
    }

    private func subject(of userID: UUID, platformID: UUID, on app: Application) async throws -> String? {
        try await APILTIIdentity.query(on: app.db)
            .filter(\.$platformID == platformID)
            .filter(\.$userID == userID)
            .first()?.subject
    }

    private static func keyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-link-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func anInstructorLinksStudentsByNumberAndTheirGradesAreQueued() async throws {
        let directory = try Self.keyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withAssignmentRoutesApp { app in
            let lms = LTITestGradeService()
            let cookie = try await arLoginAsInstructor(on: app)
            let linked = try await link(app, lms: lms, keyDirectory: directory)
            let alice = try await enrol(app, "alice", studentID: "20811111", courseID: linked.courseID)
            let bob = try await enrol(app, "bob", studentID: nil, courseID: linked.courseID)
            let admin = try await enrol(
                app, "boss", studentID: "20833333", courseID: linked.courseID, role: "admin")
            try await makeTestSetup(on: app, id: "lti-link-setup", courseID: linked.courseID)
            try await makeTestAssignment(
                on: app, testSetupID: "lti-link-setup", courseID: linked.courseID, title: "Lab 1")
            let row = APILTIGradeSync(userID: alice, testSetupID: "lti-link-setup", pendingSince: Date())
            row.pending = false
            row.error = LTIGradeSyncSweep.notLaunchedMessage
            row.failure = .notLaunched
            try await row.save(on: app.db)
            await lms.setMembers([
                LTIRosterPreLinkTests.learner("subject-a", "20811111"),
                LTIRosterPreLinkTests.learner("subject-b", "20822222"),
                LTIRosterPreLinkTests.learner("subject-c", "20833333"),
            ])

            try await get(app, "/instructor/lti-grades", cookie: cookie) { res in
                #expect(res.body.string.contains("/instructor/lti-grades/link-students"))
            }
            try await postLink(app, cookie: cookie) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/instructor/lti-grades?done=link&linked=1")
            }

            #expect(try await subject(of: alice, platformID: linked.platformID, on: app) == "subject-a")
            #expect(try await subject(of: bob, platformID: linked.platformID, on: app) == nil)
            #expect(try await subject(of: admin, platformID: linked.platformID, on: app) == nil)
            let requeued = try #require(try await APILTIGradeSync.find(try row.requireID(), on: app.db))
            #expect(requeued.pending)
            #expect(requeued.error == nil)
            let actions = try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
            #expect(actions.contains(AuditAction.ltiStudentsLinked.rawValue))

            try await get(app, "/instructor/lti-grades?done=link&linked=1", cookie: cookie) { res in
                #expect(res.body.string.contains("1 student is now linked to the LMS."))
            }
            // A second run finds nobody new.
            try await postLink(app, cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/instructor/lti-grades?done=link&linked=0")
            }
        }
    }

    @Test func aMembershipWithoutStudentNumbersSaysSo() async throws {
        let directory = try Self.keyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withAssignmentRoutesApp { app in
            let lms = LTITestGradeService()
            let cookie = try await arLoginAsInstructor(on: app)
            let linked = try await link(app, lms: lms, keyDirectory: directory)
            let alice = try await enrol(app, "alice", studentID: "20811111", courseID: linked.courseID)
            await lms.setMembers([LTIRosterPreLinkTests.learner("subject-a", nil)])
            try await postLink(app, cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/instructor/lti-grades?error=numbers")
            }
            #expect(try await subject(of: alice, platformID: linked.platformID, on: app) == nil)
            try await get(app, "/instructor/lti-grades?error=numbers", cookie: cookie) { res in
                #expect(res.body.string.contains("The LMS does not send student numbers"))
            }
        }
    }

    @Test func aCourseOnTheValenceSyncDoesNotOfferIt() async throws {
        let directory = try Self.keyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withAssignmentRoutesApp { app in
            let lms = LTITestGradeService()
            let cookie = try await arLoginAsInstructor(on: app)
            let linked = try await link(app, lms: lms, keyDirectory: directory)
            let course = try #require(try await APICourse.find(linked.courseID, on: app.db))
            course.ltiGradesEnabled = false
            try await course.save(on: app.db)
            let alice = try await enrol(app, "alice", studentID: "20811111", courseID: linked.courseID)
            await lms.setMembers([LTIRosterPreLinkTests.learner("subject-a", "20811111")])

            try await get(app, "/instructor/lti-grades", cookie: cookie) { res in
                #expect(!res.body.string.contains("/instructor/lti-grades/link-students"))
            }
            try await postLink(app, cookie: cookie) { res in
                #expect(res.headers.first(name: .location) == "/instructor/lti-grades?error=transport")
            }
            #expect(try await subject(of: alice, platformID: linked.platformID, on: app) == nil)
        }
    }

    private func get(
        _ app: Application, _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try check(try await getResponse(path, cookie: cookie, on: app))
    }
}
