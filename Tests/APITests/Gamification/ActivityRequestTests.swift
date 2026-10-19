// Tests/APITests/Gamification/ActivityRequestTests.swift
//
// The class-activity page gate, `ActivityRequest.resolve` (#2720), and the
// one avatar identity that the activity pages read, `AvatarIdentity`. A
// test-only route calls the gate, so these tests pin the gate itself and not
// one page.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct ActivityRequestTests {

    private func manifest(_ activity: ClassActivity?) throws -> String {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")],
            language: nil,
            activity: activity)
        return try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
    }

    private func makeSetup(
        _ app: Application, id: String, courseID: UUID, activity: ClassActivity?
    ) async throws {
        let setup = APITestSetup(
            id: id, manifest: try manifest(activity),
            zipPath: app.testSetupsDirectory + "\(id).zip", courseID: courseID)
        try await setup.save(on: app.db)
    }

    /// Registers `GET /test/activity/:testSetupID?audience=staff|course`,
    /// which accepts only a bracket activity when `bracket=1`. It answers
    /// "staff" or "student".
    private func registerProbe(on app: Application) {
        app.get("test", "activity", ":testSetupID") { req async throws -> String in
            let audience: ActivityRequest.Audience =
                req.query[String.self, at: "audience"] == "staff" ? .staff : .course
            let bracketOnly = req.query[String.self, at: "bracket"] == "1"
            let gate = try await ActivityRequest.resolve(
                req, resource: "Probe", audience: audience,
                matching: { !bracketOnly || $0.kind.aggregation == .bracket })
            return gate.isStaff ? "staff" : "student"
        }
    }

    private func probe(_ app: Application, cookie: String, path: String) async throws -> (HTTPStatus, String) {
        var result: (HTTPStatus, String) = (.internalServerError, "")
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in result = (res.status, res.body.string) })
        return result
    }

    @Test func missingSetupOrActivityOrKindIsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            registerProbe(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await makeSetup(app, id: "plain_setup", courseID: courseID, activity: nil)
            try await makeSetup(app, id: "best_setup", courseID: courseID, activity: ClassActivity(kind: .bestMetric))
            let cookie = try await loginAsCourseTA("testta", on: app)

            let (missing, _) = try await probe(app, cookie: cookie, path: "/test/activity/nope")
            #expect(missing == .notFound)
            let (noActivity, _) = try await probe(app, cookie: cookie, path: "/test/activity/plain_setup")
            #expect(noActivity == .notFound)
            let (wrongKind, _) = try await probe(app, cookie: cookie, path: "/test/activity/best_setup?bracket=1")
            #expect(wrongKind == .notFound)
            let (right, body) = try await probe(app, cookie: cookie, path: "/test/activity/best_setup")
            #expect(right == .ok)
            #expect(body == "staff")
        }
    }

    @Test func staffAudienceHidesThePageFromStudents() async throws {
        try await withAssignmentRoutesApp { app in
            registerProbe(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await makeSetup(
                app, id: "bracket_setup", courseID: courseID, activity: ClassActivity(kind: .elimination))
            let student = try await arLoginAsStudent(on: app)
            let ta = try await loginAsCourseTA("testta", on: app)
            let path = "/test/activity/bracket_setup?audience=staff&bracket=1"

            let (studentStatus, _) = try await probe(app, cookie: student, path: path)
            #expect(studentStatus == .notFound)
            let (taStatus, taBody) = try await probe(app, cookie: ta, path: path)
            #expect(taStatus == .ok)
            #expect(taBody == "staff")
        }
    }

    @Test func courseAudienceAdmitsEnrolledStudentsOnly() async throws {
        try await withAssignmentRoutesApp { app in
            registerProbe(on: app)
            let courseID = try await app.testCourseID(enrollmentMode: .auto)
            try await makeSetup(app, id: "best_setup", courseID: courseID, activity: ClassActivity(kind: .bestMetric))
            // A course the student is not enrolled in.
            let otherID = try await makeTestCourse(on: app, code: "OTHER1", mode: .open).requireID()
            try await makeSetup(app, id: "other_setup", courseID: otherID, activity: ClassActivity(kind: .bestMetric))
            let student = try await arLoginAsStudent(on: app)

            let (enrolled, body) = try await probe(app, cookie: student, path: "/test/activity/best_setup")
            #expect(enrolled == .ok)
            #expect(body == "student")
            let (outsider, _) = try await probe(app, cookie: student, path: "/test/activity/other_setup")
            #expect(outsider == .forbidden)
        }
    }

    // MARK: - AvatarIdentity

    @Test func avatarIdentityDrawsTheStaffRingAndHidesNames() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "CS136").requireID()
            let student = try await makeTestUser(on: app, username: "pupil")
            let studentID = try student.requireID()
            try await makeTestEnrollment(on: app, userID: studentID, courseID: courseID)
            let ta = try await makeTestUser(on: app, username: "helper")
            let taID = try ta.requireID()
            try await APICourseEnrollment(userID: taID, courseID: courseID, role: .ta).save(on: app.db)
            let dropped = try await makeTestUser(on: app, username: "gone").requireID()

            let identity = try await AvatarIdentity.load(
                userIDs: [studentID, taID, dropped], courseID: courseID, on: app.db)
            #expect(identity.isOnRoster(studentID))
            #expect(!identity.isOnRoster(dropped))

            let staffRing = "#av-ring-\(AvatarRing.staff.rawValue)"
            let studentCard = try #require(
                try await identity.presentation(for: studentID, includeName: false, fallbackLabel: "You", on: app.db))
            #expect(!studentCard.handle.isEmpty)
            #expect(studentCard.name.isEmpty)
            #expect(studentCard.avatar.ringSymbolRef != staffRing)

            let taCard = try #require(
                try await identity.presentation(for: taID, includeName: true, fallbackLabel: "TA", on: app.db))
            #expect(taCard.name == "helper")
            #expect(taCard.avatar.ringSymbolRef == staffRing)

            #expect(
                try await identity.presentation(for: dropped, includeName: true, fallbackLabel: "", on: app.db) == nil)
        }
    }
}
