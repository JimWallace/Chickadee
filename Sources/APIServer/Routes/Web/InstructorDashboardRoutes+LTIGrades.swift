// APIServer/Routes/Web/InstructorDashboardRoutes+LTIGrades.swift
//
// The LMS grades page (docs/lti-1-3.md "Grades through AGS"): where an
// instructor sends the active course's grades through the LTI grade service
// instead of the Valence sync, and where course staff see what the AGS sweep
// sent and what failed.
//
//   GET  /instructor/lti-grades            → instructor-lti-grades.leaf
//   POST /instructor/lti-grades/transport  → choose Valence or AGS (instructor)
//   POST /instructor/lti-grades/push-all   → "Sync now": queue every student's grade (TA+)

import Core
import Fluent
import Foundation
import Vapor

/// The values the transport form posts.
enum LTIGradeTransport: String, Sendable {
    case valence
    case ags
}

struct InstructorLTIGradesContext: Encodable {
    struct Failure: Encodable {
        let student: String
        let assignment: String
        let reason: String
    }

    let currentUser: CurrentUserContext?
    let activeInstructorTab: String
    let hasActiveCourse: Bool
    let courseCode: String
    /// The LMS the course is linked to; nil = not linked.
    let platformName: String?
    let isLinked: Bool
    /// True once a launch sent the course's line-items URL.
    let hasGradeService: Bool
    let usesAGS: Bool
    /// Instructor, course not archived, and the grade service is known.
    let canChooseTransport: Bool
    /// Course staff on a course that uses AGS and is not archived.
    let canPushAll: Bool
    let sentCount: Int
    let waitingCount: Int
    let failedCount: Int
    /// The first `ltiFailureListLimit` failures; `failedCount` counts them all.
    let failures: [Failure]
    let failuresTruncated: Bool
    let flashSuccess: String?
    let flashError: String?
}

extension InstructorDashboardRoutes {
    /// The most failures the page lists; the counts cover the rest.
    static let ltiFailureListLimit = 50

    // MARK: - GET /instructor/lti-grades

    @Sendable
    func ltiGradesPage(req: Request) async throws -> View {
        let user = try req.auth.require(APIUser.self)
        let courseState = try await req.resolveActiveCourse(for: user)
        var course: APICourse?
        if let courseID = courseState.activeCourseUUID { course = try await APICourse.find(courseID, on: req.db) }
        var platform: APILTIPlatform?
        if let platformID = course?.ltiPlatformID { platform = try await APILTIPlatform.find(platformID, on: req.db) }
        let isInstructor = user.isAdmin || (courseState.active?.role ?? .student) >= .instructor
        let writable = course.map { !$0.isArchived } ?? false
        let hasGradeService = course?.ltiLineItemsURL != nil
        let usesAGS = course?.usesLTIGrades ?? false
        var rows: [APILTIGradeSync] = []
        if let course { rows = try await ltiGradeSyncRows(course: course, on: req.db) }

        let failedCount = rows.filter { !$0.pending && $0.error != nil }.count
        let ctx = InstructorLTIGradesContext(
            currentUser: try await req.courseAwareUserContext(),
            activeInstructorTab: "brightspace",
            hasActiveCourse: course != nil,
            courseCode: course?.code ?? "",
            platformName: platform?.displayName,
            isLinked: platform != nil,
            hasGradeService: hasGradeService,
            usesAGS: usesAGS,
            canChooseTransport: isInstructor && writable && platform != nil && hasGradeService,
            canPushAll: writable && usesAGS,
            sentCount: rows.filter { !$0.pending && $0.error == nil && $0.syncedAt != nil }.count,
            waitingCount: rows.filter(\.pending).count,
            failedCount: failedCount,
            failures: try await ltiFailures(rows: rows, on: req.db),
            failuresTruncated: failedCount > Self.ltiFailureListLimit,
            flashSuccess: Self.ltiGradesNotice(req.query[String.self, at: "done"]),
            flashError: Self.ltiGradesProblem(req.query[String.self, at: "error"]))
        return try await req.view.render("instructor-lti-grades", ctx)
    }

    // MARK: - POST /instructor/lti-grades/transport

    @Sendable
    func saveLTIGradeTransport(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let courseID = try await req.resolveActiveCourse(for: user).activeCourseUUID,
            let course = try await APICourse.find(courseID, on: req.db)
        else { return req.redirect(to: "/instructor/lti-grades?error=course") }
        // The transport is a course setting: instructors only, like the org-unit binding.
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .instructor, db: req.db)

        struct TransportForm: Content {
            let transport: String
        }
        guard let transport = LTIGradeTransport(rawValue: try req.content.decode(TransportForm.self).transport)
        else { throw Abort(.badRequest, reason: "Choose a grade route.") }
        if transport == .ags {
            guard course.ltiPlatformID != nil, course.ltiLineItemsURL != nil else {
                return req.redirect(to: "/instructor/lti-grades?error=service")
            }
        }
        course.ltiGradesEnabled = transport == .ags
        try await course.save(on: req.db)
        await AuditLogger.record(
            action: .ltiGradeTransportChanged, targetType: .course, targetID: courseID.uuidString,
            metadata: ["transport": transport.rawValue], courseID: courseID, on: req)
        return req.redirect(to: "/instructor/lti-grades?done=\(transport.rawValue)")
    }

    // MARK: - POST /instructor/lti-grades/push-all

    @Sendable
    func pushAllLTIGrades(req: Request) async throws -> Response {
        let user = try req.auth.require(APIUser.self)
        guard let courseID = try await req.resolveActiveCourse(for: user).activeCourseUUID,
            let course = try await APICourse.find(courseID, on: req.db)
        else { return req.redirect(to: "/instructor/lti-grades?error=course") }
        try await requireCourseWriteAccess(caller: user, courseID: courseID, atLeast: .ta, db: req.db)
        guard course.usesLTIGrades else { return req.redirect(to: "/instructor/lti-grades?error=transport") }

        let setupIDs = try await APIAssignment.query(on: req.db)
            .filter(\.$courseID == courseID)
            .all()
            .map(\.testSetupID)
        // Queued as already past the debounce window, so the next sweep (at
        // most a minute away) sends them without holding this request open.
        for setupID in setupIDs {
            try await LTIGradeSyncQueue.queueAllStudents(testSetupID: setupID, on: req.db, now: .distantPast)
        }
        await AuditLogger.record(
            action: .ltiGradesPushAll, targetType: .course, targetID: courseID.uuidString,
            courseID: courseID, on: req)
        return req.redirect(to: "/instructor/lti-grades?done=push")
    }

    // MARK: - Helpers

    private func ltiGradeSyncRows(course: APICourse, on db: Database) async throws -> [APILTIGradeSync] {
        guard let courseID = course.id else { return [] }
        let setupIDs = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseID)
            .all()
            .map(\.testSetupID)
        var rows: [APILTIGradeSync] = []
        for chunk in chunkedForInFilter(setupIDs) {
            rows += try await APILTIGradeSync.query(on: db).filter(\.$testSetupID ~~ chunk).all()
        }
        return rows
    }

    private func ltiFailures(
        rows: [APILTIGradeSync], on db: Database
    ) async throws
        -> [InstructorLTIGradesContext.Failure]
    {
        let failed = rows.filter { !$0.pending && $0.error != nil }.prefix(Self.ltiFailureListLimit)
        guard !failed.isEmpty else { return [] }
        let users = try await APIUser.query(on: db).filter(\.$id ~~ failed.map(\.userID)).all()
        let names = Dictionary(users.compactMap { user in user.id.map { ($0, user.username) } }) { first, _ in first }
        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$testSetupID ~~ Array(Set(failed.map(\.testSetupID))))
            .all()
        let titles = Dictionary(assignments.map { ($0.testSetupID, $0.title) }) { first, _ in first }
        return failed.map { row in
            InstructorLTIGradesContext.Failure(
                student: names[row.userID] ?? "Unknown student",
                assignment: titles[row.testSetupID] ?? row.testSetupID,
                reason: row.error ?? "")
        }
    }

    static func ltiGradesNotice(_ key: String?) -> String? {
        switch key {
        case LTIGradeTransport.ags.rawValue: "Grades for this course now go to the LMS through the LTI grade service."
        case LTIGradeTransport.valence.rawValue:
            "Grades for this course now go to the LMS through the LEARN grade sync."
        case "push": "Every grade is queued, and the LMS receives them within a minute."
        default: nil
        }
    }

    static func ltiGradesProblem(_ key: String?) -> String? {
        switch key {
        case "course": "Select a course first."
        case "service":
            "Open Chickadee from the LMS course once so that the LMS sends its grade service URL, then try again."
        case "transport": "This course does not send its grades through the LTI grade service."
        default: nil
        }
    }
}
