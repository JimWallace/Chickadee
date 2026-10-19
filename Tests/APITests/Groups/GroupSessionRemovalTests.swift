// Tests/APITests/Groups/GroupSessionRemovalTests.swift
//
// What a Remove on "Who joined" and a move on the Groups tab do to a student
// of a per-group activity (docs/lab-groups.md, "Presence" and decision 4):
// a removed student no longer passes the submission gate, before or after
// the close, and a student moved to another lab cannot type the old lab's
// code again.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct GroupSessionRemovalTests {

    private struct Fixture {
        let setupID: String
        let set: APICourseGroupSet
        let labA: UUID
        let labB: UUID
        let session: APIActivitySession
        let student: APIUser
    }

    /// An open per-group assignment, its Lab 101 session open, and a student
    /// in Lab 101.
    private func fixture(_ app: Application, prefix: String) async throws -> Fixture {
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
            activity: ClassActivity(kind: .bestMetric, runsPerGroup: true))
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setupID = "\(prefix)_setup"
        try await APITestSetup(
            id: setupID, manifest: manifest, zipPath: app.testSetupsDirectory + "\(setupID).zip",
            courseID: courseID
        ).save(on: app.db)
        let assignment = try await arInsertAssignment(
            testSetupID: setupID, title: "Lab \(prefix)", isOpen: true, on: app)
        let student = try await arInsertStudent(username: "\(prefix)_student", on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        try await CourseGroupStore.setMembership(userID: student.requireID(), groupID: labA, in: set, on: app.db)
        let session = try await ActivitySessionStore.open(
            assignmentID: assignment.requireID(), groupID: labA, by: nil, on: app.db)
        return Fixture(setupID: setupID, set: set, labA: labA, labB: labB, session: session, student: student)
    }

    private func refusal(_ app: Application, _ f: Fixture) async -> AssignmentSubmissionGateError? {
        do {
            _ = try await requireOpenStudentAssignment(
                for: f.setupID, user: f.student, gate: .submission, on: makeTestRequest(on: app))
            return nil
        } catch let error as AssignmentSubmissionGateError {
            return error
        } catch {
            return nil
        }
    }

    private func join(_ f: Fixture, on app: Application) async throws {
        let code = ActivitySessionCode.code(secret: f.session.codeSecret, at: Date())
        try await ActivitySessionStore.join(code: code, userID: f.student.requireID(), on: app.db)
    }

    @Test func aRemovedStudentNoLongerPassesTheGate() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app, prefix: "removed")
            try await join(f, on: app)
            #expect(await refusal(app, f) == nil)

            let removed = try await ActivitySessionStore.remove(
                userID: f.student.requireID(), from: f.session, on: app.db)
            #expect(removed)
            #expect(await refusal(app, f) == .notInGroupSession)

            try await ActivitySessionStore.close(f.session, on: app.db)
            #expect(await refusal(app, f) == .notInGroupSession, "a removed student stays out after the close")
        }
    }

    @Test func aStudentMovedToAnotherLabCannotTypeTheOldCode() async throws {
        try await withAssignmentRoutesApp { app in
            let f = try await fixture(app, prefix: "moved")
            try await join(f, on: app)

            try await CourseGroupStore.setMembership(
                userID: f.student.requireID(), groupID: f.labB, in: f.set, on: app.db)
            await #expect(throws: ActivitySessionError.otherGroup(session: "Lab 101", own: "Lab 102")) {
                try await join(f, on: app)
            }
        }
    }
}
