// Tests/APITests/Groups/GroupSessionRoutesTests.swift
//
// The session routes of per-group activities (docs/lab-groups.md, slice 2),
// end to end: a TA starts and ends their lab's session from the present page,
// which shows the code, and each change is audited; a student, an instructor
// of another course and a TA of an archived course cannot, nor can anyone
// name a group of a second set; a student joins by code and lands on the
// assignment, except in an archived course; and the edit page's checkbox turns the
// activity per group.
//
// The start and end routes are rooted at `testsetups`, so
// `RouteAuthorizationMatrixTests` does not walk them. These tests are their
// authorization check.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class GroupSessionRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-group-sessions")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    private struct Fixture {
        let courseID: UUID
        let setupID: String
        let assignment: APIAssignment
        let course: APICourse
        let labA: UUID
    }

    private func actor(_ username: String, role: CourseRole, courseID: UUID) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "student", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    /// A course with one group and an open assignment whose activity runs
    /// per group (or not).
    private func fixture(_ code: String, runsPerGroup: Bool = true) async throws -> Fixture {
        let course = try await makeTestCourse(on: app, code: code, mode: .closed)
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
            activity: ClassActivity(kind: .bestMetric, runsPerGroup: runsPerGroup))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setupID = "\(code.lowercased())_setup"
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        return Fixture(courseID: courseID, setupID: setupID, assignment: assignment, course: course, labA: labA)
    }

    @discardableResult
    private func post(
        _ path: String, as actor: Actor, fields: [String: String], expecting status: HTTPStatus,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> TestResponse {
        var response: TestResponse?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                var form = fields
                form["_csrf"] = actor.csrf
                try req.content.encode(form, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == status, "POST \(path): \(res.body.string)", sourceLocation: sourceLocation)
                response = res
            })
        return try #require(response)
    }

    private func session(_ f: Fixture) async throws -> APIActivitySession? {
        try await ActivitySessionStore.session(assignmentID: f.assignment.requireID(), groupID: f.labA, on: app.db)
    }

    // MARK: - Staff

    @Test func aTAStartsAndEndsTheirLabsSession() async throws {
        try await withApp(app) { app in
            let f = try await fixture("SES1")
            let ta = try await actor("ses_ta", role: .ta, courseID: f.courseID)
            let present = "/testsetups/\(f.setupID)/leaderboard?present=1"

            let before = try await getHTML(present, cookie: ta.cookie, on: app)
            #expect(before.contains("Start session"))

            let started = try await post(
                "/testsetups/\(f.setupID)/sessions/start", as: ta, fields: ["groupID": f.labA.uuidString],
                expecting: .seeOther)
            #expect(started.headers.first(name: .location)?.contains("group=\(f.labA.uuidString)") == true)
            let open = try #require(try await session(f))
            #expect(open.closedAt == nil)
            try await post(
                "/testsetups/\(f.setupID)/sessions/start", as: ta, fields: ["groupID": f.labA.uuidString],
                expecting: .seeOther)
            #expect(try await session(f)?.joinCode == open.joinCode, "a second Start keeps the code")

            let during = try await getHTML(present, cookie: ta.cookie, on: app)
            #expect(during.contains(open.joinCode), "the projector shows the code")
            #expect(during.contains("End session"))

            try await post(
                "/testsetups/\(f.setupID)/sessions/end", as: ta, fields: ["groupID": f.labA.uuidString],
                expecting: .seeOther)
            #expect(try await session(f)?.closedAt != nil)
            let after = try await getHTML(present, cookie: ta.cookie, on: app)
            #expect(after.contains("Reopen session"))
            #expect(!after.contains(open.joinCode), "an ended session's code leaves the wall")

            let audited = try await APIAuditLogEntry.query(on: app.db)
                .filter(\.$action == AuditAction.activityGroupSessionChanged.rawValue)
                .count()
            #expect(audited == 2, "the start and the end are audited, and the second Start is not")
        }
    }

    @Test func anArchivedCourseRefusesAStart() async throws {
        try await withApp(app) { app in
            let f = try await fixture("SES7")
            let ta = try await actor("ses_ta7", role: .ta, courseID: f.courseID)
            f.course.isArchived = true
            try await f.course.save(on: app.db)
            try await post(
                "/testsetups/\(f.setupID)/sessions/start", as: ta, fields: ["groupID": f.labA.uuidString],
                expecting: .forbidden)
            #expect(try await session(f) == nil)
        }
    }

    @Test func aStudentAndAnotherCoursesInstructorCannotStartASession() async throws {
        try await withApp(app) { _ in
            let f = try await fixture("SES2")
            let other = try await fixture("SES3")
            let student = try await actor("ses_student", role: .student, courseID: f.courseID)
            let outsider = try await actor("ses_outsider", role: .instructor, courseID: other.courseID)
            for actor in [student, outsider] {
                try await post(
                    "/testsetups/\(f.setupID)/sessions/start", as: actor, fields: ["groupID": f.labA.uuidString],
                    expecting: .forbidden)
            }
            #expect(try await session(f) == nil)
        }
    }

    @Test func anActivityThatDoesNotRunPerGroupHasNoSessions() async throws {
        try await withApp(app) { _ in
            let f = try await fixture("SES4", runsPerGroup: false)
            let ta = try await actor("ses_ta4", role: .ta, courseID: f.courseID)
            try await post(
                "/testsetups/\(f.setupID)/sessions/start", as: ta, fields: ["groupID": f.labA.uuidString],
                expecting: .notFound)
        }
    }

    @Test func aGroupOfASecondSetHasNoSession() async throws {
        try await withApp(app) { app in
            let f = try await fixture("SES8")
            let ta = try await actor("ses_ta8", role: .ta, courseID: f.courseID)
            let other = try await CourseGroupStore.createSet(courseID: f.courseID, name: "Project teams", on: app.db)
            let team = try await CourseGroupStore.addGroup(named: "Team 1", to: other, on: app.db).requireID()
            try await post(
                "/testsetups/\(f.setupID)/sessions/start", as: ta, fields: ["groupID": team.uuidString],
                expecting: .notFound)
        }
    }

    // MARK: - Joining

    @Test func aStudentJoinsByCodeAndLandsOnTheAssignment() async throws {
        try await withApp(app) { app in
            let f = try await fixture("SES5")
            let student = try await actor("ses_joiner", role: .student, courseID: f.courseID)
            let open = try await ActivitySessionStore.open(
                assignmentID: f.assignment.requireID(), groupID: f.labA, by: nil, on: app.db)

            let page = try await getHTML("/join", cookie: student.cookie, on: app)
            #expect(page.contains("Enter the code on the screen in your lab."))

            let wrong = try await post("/join", as: student, fields: ["code": "QQQQQ"], expecting: .ok)
            #expect(wrong.body.string.contains("No session has that code"))

            let joined = try await post(
                "/join", as: student, fields: ["code": open.joinCode.lowercased()], expecting: .seeOther)
            #expect(
                joined.headers.first(name: .location)
                    == VanityURLRoutes.vanityPath(courseCode: f.course.urlKey, assignmentSlug: f.assignment.slug))
        }
    }

    @Test func anArchivedCourseRefusesAJoin() async throws {
        try await withApp(app) { app in
            let f = try await fixture("SES9")
            let student = try await actor("ses_joiner9", role: .student, courseID: f.courseID)
            let open = try await ActivitySessionStore.open(
                assignmentID: f.assignment.requireID(), groupID: f.labA, by: nil, on: app.db)
            f.course.isArchived = true
            try await f.course.save(on: app.db)
            let refused = try await post("/join", as: student, fields: ["code": open.joinCode], expecting: .ok)
            #expect(refused.body.string.contains(ActivitySessionError.sessionClosed.description))
            let attended = try await APIActivitySessionAttendance.query(on: app.db).count()
            #expect(attended == 0)
        }
    }

    // MARK: - The edit page

    @Test func theSessionFormTurnsTheActivityPerGroup() async throws {
        try await withApp(app) { app in
            let f = try await fixture("SES6", runsPerGroup: false)
            let instructor = try await actor("ses_inst", role: .instructor, courseID: f.courseID)
            try await post(
                "/instructor/\(f.assignment.publicID)/activity/window", as: instructor,
                fields: ["opensAt": "", "closesAt": "", "runsPerGroup": "on"], expecting: .seeOther)
            let setup = try #require(try await APITestSetup.find(f.setupID, on: app.db))
            #expect(setup.decodedManifest()?.activity?.runsPerGroup == true)

            try await post(
                "/instructor/\(f.assignment.publicID)/activity/window", as: instructor,
                fields: ["opensAt": "", "closesAt": ""], expecting: .seeOther)
            let cleared = try #require(try await APITestSetup.find(f.setupID, on: app.db))
            #expect(cleared.decodedManifest()?.activity?.runsPerGroup == false, "an unticked box turns it off")
        }
    }
}
