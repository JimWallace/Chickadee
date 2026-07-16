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

import Core
import Fluent
import Foundation

/// The user IDs of the real students in `courseID`: enrollments whose per-course
/// role is `.student` (#417 Slice G2 — the discriminator moved off the retired
/// global `APIUser.role == "student"` onto the per-course enrollment role).
/// Naturally excludes TA/instructor enrollments (a staff member enrolled to see
/// the course), which is the whole point. Empty when the course has no students.
func studentUserIDsInCourse(_ courseID: UUID, on db: Database) async throws -> Set<UUID> {
    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .all()
    return Set(enrollments.filter { $0.role == .student }.map(\.userID))
}

/// Batch variant of `studentUserIDsInCourse` — one enrollments query for all
/// `courseIDs`.  Used by the class-goal sweep to keep its numerator to real,
/// currently-enrolled students (audit A7: staff test submissions and dropped
/// students used to inflate `studentsMeeting` while the denominator counted
/// only enrolled students).
func studentUserIDsByCourse(
    courseIDs: [UUID], on db: Database
) async throws -> [UUID: Set<UUID>] {
    guard !courseIDs.isEmpty else { return [:] }
    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id ~~ courseIDs)
        .all()
    var map: [UUID: Set<UUID>] = [:]
    for e in enrollments where e.role == .student {
        map[e.$course.id, default: []].insert(e.userID)
    }
    return map
}

/// Map of `courseID → enrolled-student count` for every course that has
/// at least one student or pre-enrollment.  Courses with no roster do not
/// appear in the map; callers should fall back to 0.
///
/// Pass `courseIDs` to scope the fetch (#1160) — the class-goal achievement
/// sweep only needs the courses that carry goals, and the unscoped fetch
/// grows with every past term. nil keeps the deployment-wide behaviour the
/// admin dashboard needs.
func enrolledStudentCountsByCourse(
    courseIDs: [UUID]? = nil, on db: Database
) async throws -> [UUID: Int] {
    let enrollmentQuery = APICourseEnrollment.query(on: db)
    let preEnrollmentQuery = APIPreEnrollment.query(on: db)
    if let courseIDs {
        guard !courseIDs.isEmpty else { return [:] }
        _ = enrollmentQuery.filter(\.$course.$id ~~ courseIDs)
        _ = preEnrollmentQuery.filter(\.$course.$id ~~ courseIDs)
    }
    async let enrollmentsFetch = enrollmentQuery.all()
    async let preEnrollmentsFetch = preEnrollmentQuery.all()
    let (enrollments, preEnrollments) = try await (enrollmentsFetch, preEnrollmentsFetch)

    var counts: [UUID: Int] = [:]
    // A student in a course is a `.student`-role enrollment; TA/instructor
    // enrollments (staff who joined to see the course) don't count (#417 G2).
    for e in enrollments where e.role == .student {
        counts[e.$course.id, default: 0] += 1
    }
    for p in preEnrollments {
        counts[p.$course.id, default: 0] += 1
    }
    return counts
}

/// Single-course variant of `enrolledStudentCountsByCourse`.
func enrolledStudentCount(forCourse courseID: UUID, on db: Database) async throws -> Int {
    async let enrollmentsFetch = APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .all()
    async let preCountFetch = APIPreEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .count()
    let (enrollments, preCount) = try await (enrollmentsFetch, preCountFetch)
    let studentCount = enrollments.filter { $0.role == .student }.count
    return studentCount + preCount
}
