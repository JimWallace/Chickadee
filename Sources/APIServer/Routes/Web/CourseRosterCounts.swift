// APIServer/Routes/Web/CourseRosterCounts.swift
//
// Canonical "enrolled students" count for a course.
//
// Defined as:
//   (users with role == "student" who have an APICourseEnrollment row)
//   + (APIPreEnrollment rows — CSV-uploaded students who haven't logged in yet)
//
// Excludes instructors and admins, even when they have enrollment rows of
// their own (e.g. a TA enrolled to see the course).  Used wherever the UI
// shows "Students: N" or "X / N submitted" so the same number appears on
// the admin dashboard, the instructor dashboard, and the assignment
// submissions page.

import Fluent
import Foundation

/// Map of `courseID → enrolled-student count` for every course that has
/// at least one student or pre-enrollment.  Courses with no roster do not
/// appear in the map; callers should fall back to 0.
func enrolledStudentCountsByCourse(on db: Database) async throws -> [UUID: Int] {
    async let studentIDsFetch = APIUser.query(on: db)
        .filter(\.$role == "student")
        .all()
        .map { $0.id }
    async let enrollmentsFetch = APICourseEnrollment.query(on: db).all()
    async let preEnrollmentsFetch = APIPreEnrollment.query(on: db).all()

    let (studentIDOpts, enrollments, preEnrollments) =
        try await (studentIDsFetch, enrollmentsFetch, preEnrollmentsFetch)
    let studentIDs = Set(studentIDOpts.compactMap { $0 })

    var counts: [UUID: Int] = [:]
    for e in enrollments where studentIDs.contains(e.userID) {
        counts[e.$course.id, default: 0] += 1
    }
    for p in preEnrollments {
        counts[p.$course.id, default: 0] += 1
    }
    return counts
}

/// Single-course variant of `enrolledStudentCountsByCourse`.
func enrolledStudentCount(forCourse courseID: UUID, on db: Database) async throws -> Int {
    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .all()
    let enrolledUserIDs = enrollments.map(\.userID)
    async let studentCountFetch: Int =
        enrolledUserIDs.isEmpty
        ? 0
        : APIUser.query(on: db)
            .filter(\.$role == "student")
            .filter(\.$id ~~ enrolledUserIDs)
            .count()
    async let preCountFetch = APIPreEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .count()
    let (studentCount, preCount) = try await (studentCountFetch, preCountFetch)
    return studentCount + preCount
}
