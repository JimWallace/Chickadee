// APIServer/Helpers/Request+CourseRoleMemo.swift
//
// The course-role lookups of `Services/CourseAccess.swift`, memoized on the
// request. Split from that file in #2775: the lookups take a database, and
// only this memo takes a `Request`.

import Core
import Fluent
import Foundation
import Vapor

/// Request-storage key for the per-request `(user, course) → role` memo.
private struct CourseRoleMemoKey: StorageKey {
    typealias Value = [CourseRoleMemoIdentity: CourseRole?]
}

/// One (user, course) lookup in the per-request memo.
private struct CourseRoleMemoIdentity: Hashable {
    let userID: UUID
    let courseID: UUID
}

extension Request {
    /// `courseRole(of:inCourse:db:)` memoized on the request — the same
    /// per-request caching `resolveActiveCourse` gets.  The notebook page
    /// resolved the identical (user, course) role four times per load through
    /// its enrollment guard, staff check, effectively-open check, and
    /// closed-assignment gate; each request now pays for one enrollment read.
    /// A nil role ("not enrolled") is memoized too — entry presence, not
    /// value, marks the cache hit.
    func cachedCourseRole(of userID: UUID, inCourse courseID: UUID) async throws -> CourseRole? {
        let identity = CourseRoleMemoIdentity(userID: userID, courseID: courseID)
        if let cached = storage[CourseRoleMemoKey.self]?[identity] { return cached }
        let role = try await courseRole(of: userID, inCourse: courseID, db: db)
        var memo = storage[CourseRoleMemoKey.self] ?? [:]
        memo[identity] = role
        storage[CourseRoleMemoKey.self] = memo
        return role
    }

    /// `isCourseStaff(_:inCourse:db:)` over the memoized role — the same TA+
    /// floor (`resolvedRoleIsStaff`), one enrollment read per request.
    func cachedIsCourseStaff(_ user: APIUser, inCourse courseID: UUID) async throws -> Bool {
        if user.isAdmin { return true }
        guard let userID = user.id else { return false }
        return resolvedRoleIsStaff(try await cachedCourseRole(of: userID, inCourse: courseID))
    }

    /// `requireCourseRole(caller:courseID:atLeast:db:)` over the memoized
    /// role — the same floor policy (`requireResolvedCourseRole`).
    func cachedRequireCourseRole(
        caller: APIUser, courseID: UUID, atLeast minimum: CourseRole
    ) async throws {
        guard !caller.isAdmin else { return }
        guard let callerID = caller.id else { throw AppError.unauthenticated }
        try requireResolvedCourseRole(
            try await cachedCourseRole(of: callerID, inCourse: courseID), atLeast: minimum)
    }

    /// `requireCourseEnrollment(caller:courseID:db:)` over the memoized role.
    func cachedRequireCourseEnrollment(caller: APIUser, courseID: UUID) async throws {
        try await cachedRequireCourseRole(caller: caller, courseID: courseID, atLeast: .student)
    }
}
