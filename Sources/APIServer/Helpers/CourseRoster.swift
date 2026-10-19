// APIServer/Helpers/CourseRoster.swift
//
// The one query for "the students in course X" and for one user's
// enrollment row in a course (#2720). It sits beside the access policy in
// `CourseAccessHelpers.swift`: `courseRole(of:inCourse:db:)` and
// `userIsEnrolled` read `enrollment(of:in:on:)`, so a role check and a
// roster read cannot disagree about which row is the user's.

import Core
import Fluent
import Foundation

enum CourseRoster {
    /// True when `enrollment` makes its user a student of the course. The
    /// rule is the typed `role` accessor: a `student` row, a NULL row (a
    /// pre-migration student) and a row with a role string that no
    /// `CourseRole` case names are all students. Only a TA or instructor row
    /// is not. Every student set reads this rule, never `roleRaw`.
    static func isStudent(_ enrollment: APICourseEnrollment) -> Bool {
        enrollment.role == .student
    }

    /// The enrollment rows of the students in `courseID`. Staff rows (a TA
    /// or instructor enrolled to see the course) are left out.
    static func studentEnrollments(in courseID: UUID, on db: any Database) async throws -> [APICourseEnrollment] {
        try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID)
            .all()
            .filter(isStudent)
    }

    /// The user IDs of the students in `courseID`. Empty when the course has
    /// no students.
    static func studentIDs(in courseID: UUID, on db: any Database) async throws -> Set<UUID> {
        Set(try await studentEnrollments(in: courseID, on: db).map(\.userID))
    }

    /// `studentIDs(in:on:)` for many courses, in one query. A course with no
    /// students is not in the map.
    static func studentIDsByCourse(_ courseIDs: [UUID], on db: any Database) async throws -> [UUID: Set<UUID>] {
        guard !courseIDs.isEmpty else { return [:] }
        let enrollments = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id ~~ courseIDs)
            .all()
        var map: [UUID: Set<UUID>] = [:]
        for enrollment in enrollments where isStudent(enrollment) {
            map[enrollment.$course.id, default: []].insert(enrollment.userID)
        }
        return map
    }

    /// The enrollment row of `userID` in `courseID`, or nil when they hold
    /// none.
    static func enrollment(
        of userID: UUID, in courseID: UUID, on db: any Database
    ) async throws -> APICourseEnrollment? {
        try await APICourseEnrollment.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$course.$id == courseID)
            .first()
    }
}
