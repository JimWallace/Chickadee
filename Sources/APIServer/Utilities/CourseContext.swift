// APIServer/Utilities/CourseContext.swift
//
// Course info safe to embed in Leaf view contexts, and the resolved
// active-course state built from it.

import Core
import Foundation

/// Lightweight course info safe to embed in Leaf view contexts.
struct CourseContext: Encodable {
    let id: String
    let code: String
    let name: String
    var isActive: Bool
    /// The caller's per-course role in this course (Phase 2 of
    /// docs/multi-course-roles.md). Carried so the nav can decide instructor
    /// surfaces from the *active course's* role rather than the global one.
    /// Behaviour-neutral today — every enrollment's role mirrors the global
    /// role (Phase 1 backfill).
    let role: CourseRole
    /// The offering's term, "Fall 2026" (docs/course-terms.md). Nil when
    /// none is recorded.
    var termLabel: String?
    /// The compact term, "F26", for the tab strip.
    var termShortLabel: String?
    /// The segment to put in a `/:courseCode/...` URL (`APICourse.urlKey`):
    /// the code, or "CS135-F26" for a course with a term. Required, so a
    /// context built without one does not compile and cannot write a bare-code
    /// link for a termed course (#1787).
    let urlKey: String
}

/// The result of resolving which course is "active" for the current request.
struct ResolvedCourseState {
    let active: CourseContext?  // nil → user is not enrolled anywhere
    let all: [CourseContext]  // all enrolled courses (isActive set on one)
    let activeCourseUUID: UUID?  // for DB query filters; nil → no active course
}
