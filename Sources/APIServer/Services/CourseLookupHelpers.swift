// APIServer/Services/CourseLookupHelpers.swift
//
// Shared course-by-code resolution for routes that accept a course code in
// the URL path (vanity URLs, instructor student-history links), and the
// duplicate-code check of the course forms.
//
// A code alone can name more than one active course once codes are unique
// per term (docs/course-terms.md). A URL therefore carries the course's
// `urlKey` ("CS135-F26"), and a bare code — an old bookmark, an LMS link, a
// hand-typed URL — resolves by the rule in `findActiveCourse(byKey:viewer:on:)`.

import Core
import Fluent
import Vapor

/// Resolves a non-archived course from a URL key: a course code ("CS135") or
/// a code with its term ("CS135-F26", `APICourse.urlKey`). Case-insensitive.
///
/// 1. An exact code match wins, so a course whose code happens to end in a
///    term-like suffix still resolves by its code.
/// 2. Otherwise a trailing "-XNN" names the term of the course with the
///    preceding code.
/// 3. When more than one course remains, the viewer's enrolled courses are
///    preferred, then the newest term (`courseListPrecedes`).
///
/// Codes are matched case-insensitively so URLs work however the user types
/// them. Fluent has no case-insensitive comparison that is portable across
/// SQLite and Postgres, so this fetches the (small) active-course set and
/// compares in Swift — one place to change if that trade-off ever shifts.
func findActiveCourse(byKey key: String, viewer: UUID?, on db: Database) async throws -> APICourse? {
    let active = try await APICourse.query(on: db)
        .filter(\.$isArchived == false)
        .all()
    let candidates = coursesMatching(key: key, in: active)
    guard candidates.count > 1 else { return candidates.first }
    return try await preferredCourse(among: candidates, viewer: viewer, on: db)
}

/// The courses in `courses` that `key` names, before any preference: every
/// course whose code is `key`, else every course whose code and term make
/// `key` as a `urlKey`.
func coursesMatching(key: String, in courses: [APICourse]) -> [APICourse] {
    let lowered = key.lowercased()
    let byCode = courses.filter { $0.code.lowercased() == lowered }
    if !byCode.isEmpty { return byCode }
    return courses.filter { $0.urlKey.lowercased() == lowered }
}

/// The one course among several to use when nothing names a term: the
/// viewer's enrolled courses first, then the newest term, then code order.
func preferredCourse(among candidates: [APICourse], viewer: UUID?, on db: Database) async throws -> APICourse? {
    var pool = candidates
    if let viewer {
        let enrolledIDs = Set(
            try await APICourseEnrollment.query(on: db)
                .filter(\.$userID == viewer)
                .filter(\.$course.$id ~~ candidates.compactMap(\.id))
                .all()
                .map(\.$course.id))
        let enrolled = pool.filter { $0.id.map(enrolledIDs.contains) ?? false }
        if !enrolled.isEmpty { pool = enrolled }
    }
    return pool.min(by: courseListPrecedes)
}

/// True when a non-archived course other than `excluding` already uses
/// `code` in the same term ("no term" is one term). This is the rule of the
/// `idx_courses_code_term_active` index, so a form can report a duplicate
/// instead of failing on the index.
///
/// Codes are compared case-insensitively, the rule `coursesMatching` applies
/// when it resolves a key. The index compares bytes, so "cs135" and "CS135"
/// could both be active in one term and both answer the key "cs135"; this
/// check refuses the second at every door that creates or renames a course
/// (#1779). Fetching the active set and comparing in Swift is the same
/// trade-off `findActiveCourse` makes.
func activeCourseCodeIsTaken(
    _ code: String, term: AcademicTerm?, excluding courseID: UUID?, on db: Database
) async throws -> Bool {
    let lowered = code.lowercased()
    return try await APICourse.query(on: db)
        .filter(\.$isArchived == false)
        .all()
        .contains { $0.id != courseID && $0.code.lowercased() == lowered && $0.term == term }
}
