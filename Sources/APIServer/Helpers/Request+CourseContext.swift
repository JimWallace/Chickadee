// APIServer/Helpers/Request+CourseContext.swift
//
// The per-request resolution of the user's active course and the
// Leaf-encodable user context built from it.

import Core
import Fluent
import Vapor

/// Per-request cache of the course-aware nav context.  `NavCourseContextMiddleware`
/// populates it once for every authenticated web request so the shared nav
/// (Instructor link + course tabs) renders on *every* page — including the
/// course-free ones (admin, account, …) whose handlers only ever build a
/// `req.currentUserContext`.
private struct CourseAwareUserContextStorageKey: StorageKey {
    typealias Value = CurrentUserContext
}

/// Per-request cache of the resolved active-course state, so the several
/// callers in one request (the nav middleware, `ActiveCourseStaffMiddleware`,
/// and the page handler) share a single DB resolution rather than each
/// re-querying — and so the auto-enroll/session side effects run once.
private struct ResolvedCourseStateStorageKey: StorageKey {
    typealias Value = ResolvedCourseState
}

extension Request {
    /// Returns a Leaf-encodable snapshot of the current user for view contexts.
    ///
    /// Prefers the course-aware context resolved once per request by
    /// `NavCourseContextMiddleware`, so the nav's Instructor link and course
    /// tabs appear on every rendered page — not just the course-scoped ones.
    /// Falls back to a course-free snapshot when no middleware has populated the
    /// cache (e.g. the MCP OAuth consent flow or any non-web request), which
    /// keeps the historical behaviour for those callers.
    var currentUserContext: CurrentUserContext? {
        if let cached = storage[CourseAwareUserContextStorageKey.self] { return cached }
        guard let user = auth.get(APIUser.self) else { return nil }
        return CurrentUserContext(user: user)
    }

    /// Builds a `CurrentUserContext` populated with course information from the DB.
    /// Call this from any route that needs course tabs or active-course filtering.
    /// The result is cached on the request so `currentUserContext` and any later
    /// caller reuse it without re-querying.
    func courseAwareUserContext() async throws -> CurrentUserContext? {
        if let cached = storage[CourseAwareUserContextStorageKey.self] { return cached }
        guard let user = auth.get(APIUser.self) else { return nil }
        let state = try await resolveActiveCourse(for: user)
        let context = CurrentUserContext(
            user: user, activeCourse: state.active, enrolledCourses: state.all)
        storage[CourseAwareUserContextStorageKey.self] = context
        return context
    }

    private static let activeCourseSessionKey = "activeCourseID"

    /// Resolves the active course for `user`, consulting the session and DB.
    /// Auto-enrolls the user in every course with enrollmentMode == .auto.
    /// Returns `activeCourseUUID == nil` when the user is not enrolled anywhere.
    /// Cached per request (the underlying work, including its side effects, runs
    /// once); see `computeActiveCourse` for the resolution itself.
    /// The active course's id, or `WebAssignmentError.noActiveCourse` naming
    /// `action` when the viewer has none selected. The guard every
    /// course-scoped instructor write starts with.
    func requireActiveCourseID(for user: APIUser, action: String) async throws -> UUID {
        guard let courseID = try await resolveActiveCourse(for: user).activeCourseUUID else {
            throw WebAssignmentError.noActiveCourse(action: action)
        }
        return courseID
    }

    func resolveActiveCourse(for user: APIUser) async throws -> ResolvedCourseState {
        if let cached = storage[ResolvedCourseStateStorageKey.self] { return cached }
        let state = try await computeActiveCourse(for: user)
        storage[ResolvedCourseStateStorageKey.self] = state
        return state
    }

    private func computeActiveCourse(for user: APIUser) async throws -> ResolvedCourseState {
        guard let userID = user.id else {
            return ResolvedCourseState(active: nil, all: [], activeCourseUUID: nil)
        }

        // Count all non-archived courses so we know if auto-enroll applies.
        let allCourses = try await APICourse.query(on: db)
            .filter(\.$isArchived == false)
            .sort(\.$createdAt)
            .all()

        guard !allCourses.isEmpty else {
            return ResolvedCourseState(active: nil, all: [], activeCourseUUID: nil)
        }

        // Fetch current enrollments.
        var enrolledContexts = try await loadEnrolledCourseContexts(userID: userID)

        // Auto-enroll in every course whose mode is .auto that the user isn't already in.
        let autoCourses = allCourses.filter { $0.enrollmentMode == .auto }
        var didEnroll = false
        for course in autoCourses {
            guard let courseID = course.id else { continue }
            let alreadyEnrolled = enrolledContexts.contains { $0.id == courseID.uuidString }
            if !alreadyEnrolled {
                try? await saveSeededEnrollment(for: user, courseID: courseID, on: db)
                didEnroll = true
            }
        }
        if didEnroll {
            enrolledContexts = try await loadEnrolledCourseContexts(userID: userID)
        }

        guard !enrolledContexts.isEmpty else {
            return ResolvedCourseState(active: nil, all: [], activeCourseUUID: nil)
        }

        // Determine active course from session, or fall back to first enrolled.
        let sessionID = session.data[Request.activeCourseSessionKey]
        let activeCourseID: String
        if let sid = sessionID, enrolledContexts.contains(where: { $0.id == sid }) {
            activeCourseID = sid
        } else {
            activeCourseID = enrolledContexts[0].id
            session.data[Request.activeCourseSessionKey] = activeCourseID
        }

        let activeCourseUUID = UUID(uuidString: activeCourseID)
        let markedCourses = enrolledContexts.map {
            CourseContext(
                id: $0.id, code: $0.code, name: $0.name,
                isActive: $0.id == activeCourseID, role: $0.role,
                termLabel: $0.termLabel, termShortLabel: $0.termShortLabel, urlKey: $0.urlKey)
        }
        let active = markedCourses.first(where: \.isActive)
        return ResolvedCourseState(active: active, all: markedCourses, activeCourseUUID: activeCourseUUID)
    }

    private func loadEnrolledCourseContexts(userID: UUID) async throws -> [CourseContext] {
        // Delegates to the shared visibility resolver (role-augmented) so the
        // tab strip and the MCP listing surface stay in lockstep on which
        // courses are visible; the per-course role rides along for the nav.
        try await enrolledCoursesWithRoles(for: userID, on: db).compactMap { pair in
            guard let id = pair.course.id else { return nil }
            return CourseContext(
                id: id.uuidString, code: pair.course.code, name: pair.course.name,
                isActive: false, role: pair.role,
                termLabel: pair.course.term?.displayName,
                termShortLabel: pair.course.term?.shortLabel,
                urlKey: pair.course.urlKey)
        }
    }
}
