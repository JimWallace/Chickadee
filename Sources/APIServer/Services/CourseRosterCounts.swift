// APIServer/Services/CourseRosterCounts.swift
//
// Canonical "enrolled students" count for a course.
//
// Defined as:
//   (the students of `CourseRoster.isStudent`)
//   + (APIPreEnrollment rows — CSV-uploaded students who haven't logged in yet)
//
// Excludes instructors and admins, even when they have enrollment rows of
// their own (e.g. a TA enrolled to see the course).  Used wherever the UI
// shows "Students: N" or "X / N submitted" so the same number appears on
// the admin dashboard, the instructor dashboard, and the assignment
// submissions page.

import Core
import Fluent
import Foundation

/// Map of `courseID → enrolled-student count` for every course that has
/// at least one student or pre-enrollment.  Courses with no roster do not
/// appear in the map; callers should fall back to 0.
///
/// Pass `courseIDs` to scope the fetch (#1160) — the class-goal achievement
/// sweep only needs the courses that carry goals, and the unscoped fetch
/// grows with every past term. nil keeps the deployment-wide behaviour the
/// admin dashboard needs.
func enrolledStudentCountsByCourse(
    courseIDs: [UUID]? = nil, on db: any Database
) async throws -> [UUID: Int] {
    // Only the course column of each student row: the admin dashboard asks
    // for every course, and loading whole rows to count them read both
    // tables in full.
    let enrollmentQuery = CourseRoster.studentsOnly(APICourseEnrollment.query(on: db))
    let preEnrollmentQuery = APIPreEnrollment.query(on: db)
    if let courseIDs {
        guard !courseIDs.isEmpty else { return [:] }
        _ = enrollmentQuery.filter(\.$course.$id ~~ courseIDs)
        _ = preEnrollmentQuery.filter(\.$course.$id ~~ courseIDs)
    }
    async let enrollmentsFetch = enrollmentQuery.all(\.$course.$id)
    async let preEnrollmentsFetch = preEnrollmentQuery.all(\.$course.$id)
    let (studentCourseIDs, preEnrollmentCourseIDs) = try await (enrollmentsFetch, preEnrollmentsFetch)

    var counts: [UUID: Int] = [:]
    // A student in a course is a `.student`-role enrollment; TA/instructor
    // enrollments (staff who joined to see the course) don't count (#417 G2).
    for courseID in studentCourseIDs {
        counts[courseID, default: 0] += 1
    }
    for courseID in preEnrollmentCourseIDs {
        counts[courseID, default: 0] += 1
    }
    return counts
}

/// Single-course variant of `enrolledStudentCountsByCourse`.
func enrolledStudentCount(forCourse courseID: UUID, on db: any Database) async throws -> Int {
    async let studentCountFetch = CourseRoster.studentsOnly(
        APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == courseID)
    )
    .count()
    async let preCountFetch = APIPreEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .count()
    let (studentCount, preCount) = try await (studentCountFetch, preCountFetch)
    return studentCount + preCount
}
