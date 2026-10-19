// Tests/APITests/PerGroupActivityFixture.swift
//
// The shared fixture for a class activity run once per lab group
// (docs/lab-groups.md): a closed course with a "Lab sections" set that holds
// Lab 101 and Lab 102, one test setup with the activity, its assignment, and
// the students in the order the caller names them. `joinSession` is the one
// back-dated session join that these suites use.

import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer
@testable import Core

struct PerGroupActivityFixture {

    /// The lab a student is a member of, or none.
    enum Lab {
        case a
        case b
    }

    let courseID: UUID
    let set: APICourseGroupSet
    let setup: APITestSetup
    let activity: ClassActivity
    let assignmentID: UUID
    /// Lab 101.
    let labA: UUID
    /// Lab 102.
    let labB: UUID
    /// The user IDs of the students, in the order given to `make`.
    let students: [UUID]

    /// Saves the course, the two labs, the setup with `activity`, the
    /// assignment, and each student. A student with a lab becomes a member of
    /// it. `withSubmissions` also saves a complete submission
    /// `<username>_s1` for each student.
    static func make(
        on app: Application,
        code: String,
        setupID: String,
        activity: ClassActivity,
        achievements: [Achievement] = [],
        students: [(username: String, lab: Lab?)],
        withSubmissions: Bool = false
    ) async throws -> PerGroupActivityFixture {
        let course = try await makeTestCourse(on: app, code: code, mode: .closed)
        let courseID = try course.requireID()
        let set = try await CourseGroupStore.createSet(courseID: courseID, name: "Lab sections", on: app.db)
        let labA = try await CourseGroupStore.addGroup(named: "Lab 101", to: set, on: app.db).requireID()
        let labB = try await CourseGroupStore.addGroup(named: "Lab 102", to: set, on: app.db).requireID()
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "match.sh")], language: nil,
            activity: activity, achievements: achievements)
        let manifest = try #require(String(data: JSONEncoder().encode(props), encoding: .utf8))
        let setup = try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: manifest)
        let assignment = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID)
        var ids: [UUID] = []
        for (username, lab) in students {
            let id = try await makeTestStudent(on: app, username: username).requireID()
            try await makeTestEnrollment(on: app, userID: id, courseID: courseID)
            if let lab {
                let group = lab == .a ? labA : labB
                try await CourseGroupStore.setMembership(userID: id, groupID: group, in: set, on: app.db)
            }
            if withSubmissions {
                try await makeTestSubmission(on: app, id: "\(username)_s1", setupID: setupID, userID: id)
            }
            ids.append(id)
        }
        return PerGroupActivityFixture(
            courseID: courseID, set: set, setup: setup,
            activity: try #require(setup.decodedManifest()?.activity),
            assignmentID: try assignment.requireID(), labA: labA, labB: labB, students: ids)
    }

    /// Joins `userID` to the session of `group`, as `joinSession` does.
    @discardableResult
    func join(_ userID: UUID, to group: UUID, on db: any Database) async throws -> APIActivitySession {
        try await joinSession(assignmentID: assignmentID, groupID: group, userID: userID, on: db)
    }
}

/// Opens the session of `groupID` a minute ago, unless it is open, and joins
/// `userID` to it with the code it showed 30 seconds ago. Returns the session.
@discardableResult
func joinSession(
    assignmentID: UUID, groupID: UUID, userID: UUID, on db: any Database
) async throws -> APIActivitySession {
    let session = try await ActivitySessionStore.open(
        assignmentID: assignmentID, groupID: groupID, by: nil, now: Date().addingTimeInterval(-60), on: db)
    let joinedAt = Date().addingTimeInterval(-30)
    try await ActivitySessionStore.join(
        code: ActivitySessionCode.code(secret: session.codeSecret, at: joinedAt), userID: userID,
        now: joinedAt, on: db)
    return session
}
