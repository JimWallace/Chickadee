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
        guard let userID = user.id, let courseID = allAssignments.first?.courseID else { return [] }
        // Staff (TA+ or admin) of the course already see every setup, so they
        // need no per-student engagement set (#417 Slice G — was the global
        // `user.isInstructor`).
        if try await isCourseStaff(user, inCourse: courseID, db: db) { return [] }
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

    /// The setups the viewer's dashboard lists.  Staff see every setup in the
    /// active course.  Enrolled students see every published assignment in the
    /// course: open ones, and ones that were published and have since closed
    /// at their deadline — kept on the list (read-only) so recent labs never
    /// silently disappear (preview / scheduled / unpublished drafts stay
    /// hidden; see `assignmentVisibleToStudentByState`) — plus anything an
    /// active per-student extension reveals and anything they previously
    /// engaged with (covers no-deadline assignments the by-state rule can't
    /// classify).  Empty when nothing is visible.
    static func loadDashboardSetups(
        activeCourseUUID: UUID,
        isActiveCourseStaff: Bool,
        allAssignments: [APIAssignment],
        extensionDueAtBySetupID: [String: Date],
        previouslyOpenedSetupIDs: Set<String>,
        db: any Database
    ) async throws -> [APITestSetup] {
        if isActiveCourseStaff {
            return try await APITestSetup.query(on: db)
                .filter(\.$courseID == activeCourseUUID)
                .sort(\.$createdAt, .descending)
                .all()
        }
        let now = Date()
        var visibleSetupIDs = Set(
            allAssignments
                .filter { assignmentVisibleToStudentByState($0, now: now) }
                .map(\.testSetupID))
        // An active per-student extension also reveals an assignment that was
        // closed before its deadline (which the by-state rule leaves hidden
        // for everyone else) to the one student who was granted more time.
        for (setupID, extendedDueAt) in extensionDueAtBySetupID
        where studentHasActiveExtension(extensionDueAt: extendedDueAt, now: now) {
            visibleSetupIDs.insert(setupID)
        }
        visibleSetupIDs.formUnion(previouslyOpenedSetupIDs)
        guard !visibleSetupIDs.isEmpty else { return [] }
        return try await APITestSetup.query(on: db)
            .filter(\.$id ~~ visibleSetupIDs)
            .sort(\.$createdAt, .descending)
            .all()
    }

    /// Notebook presence per setup — drives the Edit button.  The zip-derived
    /// answer costs an `unzip` subprocess per setup, so it is resolved through
    /// ZipEntryListCache (keyed by zip mtime + size) instead of being
    /// recomputed on every dashboard view.
    static func loadHasNotebookBySetupID(
        setups: [APITestSetup], application: Application
    ) async -> [String: Bool] {
        var hasNotebookBySetupID: [String: Bool] = [:]
        for setup in setups {
            let setupID = setup.id ?? ""
            if let path = setup.notebookPath, !path.isEmpty,
                FileManager.default.fileExists(atPath: path)
            {
                hasNotebookBySetupID[setupID] = true
            } else {
                hasNotebookBySetupID[setupID] = await application.zipEntryListCache
                    .zipContainsNotebook(zipPath: setup.zipPath)
            }
        }
        return hasNotebookBySetupID
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
