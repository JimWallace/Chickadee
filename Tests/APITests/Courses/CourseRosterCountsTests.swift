// Tests/APITests/Courses/CourseRosterCountsTests.swift
//
// The "enrolled students" counts filter by role in the database. They must
// keep the student rule of `CourseRoster.isStudent`: a `student` row, a NULL
// row and a row with an unknown role string count, a TA or instructor row
// does not, and each pre-enrollment counts.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized) struct CourseRosterCountsTests {

    private func enroll(
        _ username: String, roleRaw: String?, in courseID: UUID, on app: Application
    ) async throws {
        let user = try await makeTestUser(on: app, username: username)
        let enrollment = APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: .student)
        enrollment.roleRaw = roleRaw
        try await enrollment.save(on: app.db)
    }

    /// Three students, two staff and one pre-enrollment in `courseID`.
    private func seed(_ prefix: String, in courseID: UUID, on app: Application) async throws {
        try await enroll("\(prefix)_pupil", roleRaw: CourseRole.student.rawValue, in: courseID, on: app)
        try await enroll("\(prefix)_legacy", roleRaw: nil, in: courseID, on: app)
        try await enroll("\(prefix)_odd", roleRaw: "auditor", in: courseID, on: app)
        try await enroll("\(prefix)_helper", roleRaw: CourseRole.ta.rawValue, in: courseID, on: app)
        try await enroll("\(prefix)_prof", roleRaw: CourseRole.instructor.rawValue, in: courseID, on: app)
        try await APIPreEnrollment(courseID: courseID, username: "\(prefix)_pending").save(on: app.db)
    }

    @Test func singleCourseCountKeepsTheStudentRule() async throws {
        try await withTestApp { app in
            let courseID = try await makeTestCourse(on: app, code: "CS136").requireID()
            try await seed("one", in: courseID, on: app)

            #expect(try await enrolledStudentCount(forCourse: courseID, on: app.db) == 4)
        }
    }

    @Test func batchedCountsMatchTheSingleCourseCount() async throws {
        try await withTestApp { app in
            let first = try await makeTestCourse(on: app, code: "CS136").requireID()
            let second = try await makeTestCourse(on: app, code: "CS246").requireID()
            let empty = try await makeTestCourse(on: app, code: "CS341").requireID()
            try await seed("a", in: first, on: app)
            try await seed("b", in: second, on: app)
            try await enroll("b_extra", roleRaw: CourseRole.student.rawValue, in: second, on: app)

            let all = try await enrolledStudentCountsByCourse(on: app.db)
            #expect(all[first] == 4)
            #expect(all[second] == 5)
            #expect(all[empty] == nil)

            let scoped = try await enrolledStudentCountsByCourse(courseIDs: [second], on: app.db)
            #expect(scoped == [second: 5])
            #expect(try await enrolledStudentCount(forCourse: second, on: app.db) == 5)
        }
    }
}
