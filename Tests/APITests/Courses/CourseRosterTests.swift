// Tests/APITests/Courses/CourseRosterTests.swift
//
// `CourseRoster`, the one query for the students of a course and for one
// user's enrollment row (#2720). The suite pins the student rule: a
// `student` row, a NULL row and a row with an unknown role string are all
// students, and only a TA or instructor row is not. The copies that this
// type replaced did not agree on the unknown-role row.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct CourseRosterTests {

    /// One user per kind of enrollment row in `courseID`, by username.
    private struct Roster {
        let student: UUID
        let nullRole: UUID
        let unknownRole: UUID
        let ta: UUID
        let instructor: UUID
    }

    private func enroll(
        _ username: String, roleRaw: String?, in courseID: UUID, on app: Application
    ) async throws -> UUID {
        let user = try await makeTestUser(on: app, username: username)
        let userID = try user.requireID()
        let enrollment = APICourseEnrollment(userID: userID, courseID: courseID, role: .student)
        enrollment.roleRaw = roleRaw
        try await enrollment.save(on: app.db)
        return userID
    }

    private func seedRoster(in courseID: UUID, on app: Application) async throws -> Roster {
        Roster(
            student: try await enroll("pupil", roleRaw: CourseRole.student.rawValue, in: courseID, on: app),
            nullRole: try await enroll("legacy", roleRaw: nil, in: courseID, on: app),
            unknownRole: try await enroll("odd", roleRaw: "auditor", in: courseID, on: app),
            ta: try await enroll("helper", roleRaw: CourseRole.ta.rawValue, in: courseID, on: app),
            instructor: try await enroll("prof", roleRaw: CourseRole.instructor.rawValue, in: courseID, on: app))
    }

    @Test func studentSetHoldsNullAndUnknownRolesAndNoStaff() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "CS136").requireID()
            let roster = try await seedRoster(in: courseID, on: app)

            let students = try await CourseRoster.studentIDs(in: courseID, on: app.db)
            #expect(students == [roster.student, roster.nullRole, roster.unknownRole])

            let rows = try await CourseRoster.studentEnrollments(in: courseID, on: app.db)
            #expect(Set(rows.map(\.userID)) == students)
        }
    }

    @Test func studentRuleMatchesTheRoleAccessor() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "CS136").requireID()
            let roster = try await seedRoster(in: courseID, on: app)

            for userID in [roster.student, roster.nullRole, roster.unknownRole] {
                let row = try #require(try await CourseRoster.enrollment(of: userID, in: courseID, on: app.db))
                #expect(CourseRoster.isStudent(row))
                #expect(try await courseRole(of: userID, inCourse: courseID, db: app.db) == .student)
            }
            for userID in [roster.ta, roster.instructor] {
                let row = try #require(try await CourseRoster.enrollment(of: userID, in: courseID, on: app.db))
                #expect(!CourseRoster.isStudent(row))
            }
        }
    }

    @Test func batchedStudentSetMatchesTheSingleCourseSet() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "CS136").requireID()
            let staffOnlyID = try await makeTestCourse(on: app, code: "CS246").requireID()
            let emptyID = try await makeTestCourse(on: app, code: "CS350").requireID()
            _ = try await seedRoster(in: courseID, on: app)
            _ = try await enroll("other-ta", roleRaw: CourseRole.ta.rawValue, in: staffOnlyID, on: app)

            let byCourse = try await CourseRoster.studentIDsByCourse(
                [courseID, staffOnlyID, emptyID], on: app.db)
            #expect(byCourse[courseID] == (try await CourseRoster.studentIDs(in: courseID, on: app.db)))
            // A course with no students is not in the map.
            #expect(byCourse[staffOnlyID] == nil)
            #expect(byCourse[emptyID] == nil)
            #expect(try await CourseRoster.studentIDsByCourse([], on: app.db).isEmpty)
        }
    }

    @Test func enrollmentIsScopedToTheCourse() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "CS136").requireID()
            let otherID = try await makeTestCourse(on: app, code: "CS246").requireID()
            let userID = try await enroll("pupil", roleRaw: CourseRole.student.rawValue, in: courseID, on: app)

            #expect(try await CourseRoster.enrollment(of: userID, in: courseID, on: app.db)?.userID == userID)
            #expect(try await CourseRoster.enrollment(of: userID, in: otherID, on: app.db) == nil)
            #expect(try await userIsEnrolled(userID: userID, inCourse: courseID, db: app.db))
            #expect(try await !userIsEnrolled(userID: userID, inCourse: otherID, db: app.db))
        }
    }

    /// The classmate chooser used to filter `student OR NULL` in SQL, which
    /// left out a row with an unknown role string. It reads the roster now.
    @Test func classmateChooserReadsTheRosterRule() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "CS136").requireID()
            let roster = try await seedRoster(in: courseID, on: app)
            let setup = try await makeTestSetup(on: app, id: "setup-roster", courseID: courseID)
            let setupID = try setup.requireID()
            for (index, userID) in [roster.student, roster.nullRole, roster.unknownRole, roster.ta].enumerated() {
                try await makeTestSubmission(on: app, id: "sub-roster-\(index)", setupID: setupID, userID: userID)
            }

            let latest = try await latestStudentSubmissionsByUser(setup: setup, on: app.db)
            #expect(Set(latest.keys) == [roster.student, roster.nullRole, roster.unknownRole])

            let excluding = try await latestStudentSubmissionsByUser(
                setup: setup, excluding: roster.unknownRole, on: app.db)
            #expect(Set(excluding.keys) == [roster.student, roster.nullRole])
        }
    }
}
