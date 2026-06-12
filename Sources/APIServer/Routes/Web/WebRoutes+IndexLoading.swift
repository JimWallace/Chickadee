// APIServer/Routes/Web/WebRoutes+IndexLoading.swift
//
// Batched data-loading helpers for the student dashboard (GET /).  Extracted
// from the index handler so the independent reads can run concurrently via
// `async let` — the handler previously issued every query sequentially, so a
// dashboard view paid each DB round trip back to back.  Each helper owns its
// own applicability guard and returns an empty value when it doesn't apply,
// which keeps the call site a flat set of `async let` bindings.

import Core
import Fluent
import Foundation
import Vapor

extension WebRoutes {
    /// Per-user active extensions keyed by testSetupID (the dashboard works
    /// in setup space; the assignment for each row is looked up separately).
    /// Loaded before the student visibility filter so an
    /// auto-closed-at-deadline assignment the student was granted more time
    /// on still appears in their list.
    static func loadExtensionDueDates(
        user: APIUser,
        allAssignments: [APIAssignment],
        db: any Database
    ) async throws -> [String: Date] {
        guard let userID = user.id, !allAssignments.isEmpty else { return [:] }
        let assignmentIDs = allAssignments.compactMap(\.id)
        let extensions = try await APIAssignmentExtension.query(on: db)
            .filter(\.$assignmentID ~~ Set(assignmentIDs))
            .filter(\.$userID == userID)
            .all()
        let setupIDByAssignmentID = setupIDByAssignmentID(allAssignments)
        var dueAtBySetupID: [String: Date] = [:]
        for row in extensions {
            guard let setupID = setupIDByAssignmentID[row.assignmentID] else { continue }
            dueAtBySetupID[setupID] = row.extendedDueAt
        }
        return dueAtBySetupID
    }

    /// Setup IDs of assignments the current student has previously engaged
    /// with.  Engagement = a durable participation row, or a student
    /// submission (the latter also bridges students who submitted before the
    /// participation table existed).  Closed assignments in this set stay
    /// visible (read-only review) and keep their Edit link.  Empty for
    /// instructors/admins — they already see every setup in the course.  The
    /// two engagement reads are independent and run concurrently.
    static func loadPreviouslyOpenedSetupIDs(
        user: APIUser,
        allAssignments: [APIAssignment],
        db: any Database
    ) async throws -> Set<String> {
        guard !user.isInstructor, let userID = user.id, !allAssignments.isEmpty else { return [] }
        let allSetupIDs = Set(allAssignments.map(\.testSetupID))
        let setupIDByAssignmentID = setupIDByAssignmentID(allAssignments)

        async let submittedFetch = APISubmission.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$testSetupID ~~ allSetupIDs)
            .filter(\.$kind == APISubmission.Kind.student)
            .all()
        async let participationsFetch = APIAssignmentParticipation.query(on: db)
            .filter(\.$userID == userID)
            .filter(\.$assignmentID ~~ Set(setupIDByAssignmentID.keys))
            .all()

        var opened = Set(try await submittedFetch.map(\.testSetupID))
        for row in try await participationsFetch {
            if let setupID = setupIDByAssignmentID[row.assignmentID] {
                opened.insert(setupID)
            }
        }
        return opened
    }

    /// Sections for the active course, used to group the dashboard rows.
    static func loadCourseSections(
        activeCourseUUID: UUID?,
        db: any Database
    ) async throws -> [APICourseSection] {
        guard let activeCourseUUID else { return [] }
        return try await APICourseSection.query(on: db)
            .filter(\.$courseID == activeCourseUUID)
            .sort(\.$sortOrder, .ascending)
            .all()
    }

    private static func setupIDByAssignmentID(
        _ assignments: [APIAssignment]
    ) -> [UUID: String] {
        Dictionary(
            uniqueKeysWithValues: assignments.compactMap { assignment -> (UUID, String)? in
                guard let id = assignment.id else { return nil }
                return (id, assignment.testSetupID)
            }
        )
    }
}
