// Tests/APITests/LTI/LTIRosterCheckTests.swift
//
// "Check against LEARN" read from the LMS through NRPS (docs/lti-1-3.md
// "Roster through NRPS"): a course with an NRPS URL and no Valence link
// offers the check, and the check flags exactly the students the LMS could
// know and does not list.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct LTIRosterCheckTests {
    /// Links the shared test course to a platform whose NRPS the stand-in
    /// LMS answers, and points the app at that LMS.
    private func link(_ app: Application, lms: LTITestGradeService, keyDirectory: URL) async throws -> (UUID, UUID) {
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
        try await course.save(on: app.db)
        return (courseID, try platform.requireID())
    }

    private func enrol(
        _ app: Application, _ username: String, courseID: UUID, platformID: UUID, subject: String? = nil
    ) async throws -> UUID {
        let user = try await makeTestUser(on: app, username: username)
        let userID = try user.requireID()
        try await APICourseEnrollment(userID: userID, courseID: courseID, role: .student).save(on: app.db)
        if let subject {
            try await APILTIIdentity(platformID: platformID, subject: subject, userID: userID).save(on: app.db)
        }
        return userID
    }

    private static func keyDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-roster-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func theCheckFlagsOnlyStudentsTheLMSCouldKnow() async throws {
        let directory = try Self.keyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withAssignmentRoutesApp { app in
            let lms = LTITestGradeService()
            let cookie = try await arLoginAsInstructor(on: app)
            let (courseID, platformID) = try await link(app, lms: lms, keyDirectory: directory)
            let alice = try await enrol(app, "alice", courseID: courseID, platformID: platformID, subject: "subject-a")
            let bob = try await enrol(app, "bob", courseID: courseID, platformID: platformID, subject: "subject-b")
            let carol = try await enrol(app, "carol", courseID: courseID, platformID: platformID)
            let pending = APIPreEnrollment(courseID: courseID, username: "dave")
            try await pending.save(on: app.db)
            await lms.setMembers(
                [
                    LTIRosterTests.member("subject-a"), LTIRosterTests.member("subject-b", status: "Inactive"),
                    LTIRosterTests.member("subject-z"),
                ], perPage: 2)

            try await app.asyncTest(
                .GET, "/instructor/students/learn-check",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let result = try res.content.decode(LearnRosterCheckResult.self)
                    #expect(result.ok)
                    #expect(result.learnCount == 2)
                    #expect(result.notOnLearn == [bob.uuidString])
                    #expect(Set(result.unverifiable) == [carol.uuidString, try pending.requireID().uuidString])
                    #expect(!result.notOnLearn.contains(alice.uuidString))
                    #expect(result.message.contains("in the LMS"))
                })
        }
    }

    /// The Students tab used to offer a "Check against LEARN" button. The
    /// readiness sweep now keeps each enrolment's status, and the roster shows
    /// it as a flag by the name, so the tab offers no check in either state.
    /// The `/instructor/students/learn-check` route itself is unchanged.
    @Test func theStudentsTabNoLongerOffersTheCheck() async throws {
        let directory = try Self.keyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withAssignmentRoutesApp { app in
            let lms = LTITestGradeService()
            let cookie = try await arLoginAsInstructor(on: app)
            try await app.asyncTest(
                .GET, "/instructor/students",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(!res.body.string.contains("learn-check-btn")) })

            _ = try await link(app, lms: lms, keyDirectory: directory)
            try await app.asyncTest(
                .GET, "/instructor/students",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in #expect(!res.body.string.contains("learn-check-btn")) })
        }
    }

    @Test func aFailedReadSaysSoWithoutFlaggingAnyone() async throws {
        let directory = try Self.keyDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try await withAssignmentRoutesApp { app in
            let lms = LTITestGradeService()
            let cookie = try await arLoginAsInstructor(on: app)
            let (courseID, _) = try await link(app, lms: lms, keyDirectory: directory)
            let course = try #require(try await APICourse.find(courseID, on: app.db))
            course.ltiMembershipsURL = "https://lms.example.edu/unknown"
            try await course.save(on: app.db)

            try await app.asyncTest(
                .GET, "/instructor/students/learn-check",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let result = try res.content.decode(LearnRosterCheckResult.self)
                    #expect(!result.ok)
                    #expect(result.notOnLearn.isEmpty)
                })
        }
    }

    @Test func aValenceLinkedCourseKeepsTheValenceClasslist() {
        let course = APICourse(code: "X", name: "X")
        course.ltiPlatformID = UUID()
        course.ltiMembershipsURL = LTITestGradeService.membershipsURL
        course.brightspaceOrgUnitID = "ou-1"
        #expect(!InstructorDashboardRoutes.rosterCheckUsesLTI(course: course, valenceConfigured: true))
        course.ltiGradesEnabled = true
        #expect(InstructorDashboardRoutes.rosterCheckUsesLTI(course: course, valenceConfigured: true))
        course.ltiGradesEnabled = false
        #expect(InstructorDashboardRoutes.rosterCheckUsesLTI(course: course, valenceConfigured: false))
        course.ltiMembershipsURL = nil
        #expect(!InstructorDashboardRoutes.rosterCheckUsesLTI(course: course, valenceConfigured: false))
    }
}
