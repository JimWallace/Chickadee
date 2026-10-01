// APIServer/Services/BrightSpaceCourseBinding.swift
//
// Binding a course to its LEARN org unit, and mapping its assignments to
// the org unit's grade items by name. Functions over models, a database and
// the application, never a `Request`: the handlers in
// `InstructorDashboardRoutes+BrightSpace.swift` decode the form, flash the
// outcome, write the audit entry and redirect. Moved out of the route
// extension in #1654 (slice 3).

import Fluent
import Foundation
import Vapor

enum BrightSpaceCourseBinding {

    /// What D2L said about the org unit after the binding was saved. The
    /// binding is saved before verification in every case: a key that cannot
    /// see the org unit is reported here, where the instructor is still
    /// holding the form, rather than at grade-push time.
    enum Verification: Equatable {
        /// D2L reported the org unit, and its name is stored on the course.
        case verified(name: String)
        /// No client resolved for the course, so nothing was checked.
        case unverified
        /// D2L reports no such org unit, or the key cannot see it.
        case notFound
        /// The lookup failed; the text is the transport's description.
        case failed(String)
    }

    /// Why an org unit could not be bound.
    enum BindError: Error, Equatable {
        /// The binder has no stored key. The org unit is verified with it,
        /// and every push runs as it.
        case binderNotConnected
    }

    /// Clears the course's org-unit binding. The sync identity is left alone.
    static func clearOrgUnit(course: APICourse, on db: Database) async throws {
        course.brightspaceOrgUnitID = nil
        course.brightspaceOrgUnitName = nil
        try await course.save(on: db)
    }

    /// Binds `orgUnitID` to the course, makes the binder the course's
    /// grade-sync identity (the "binder = default" rule), and verifies the
    /// org unit with that identity's key.
    static func bindOrgUnit(
        course: APICourse,
        orgUnitID: String,
        binderUUID: UUID,
        on db: Database,
        application: Application
    ) async throws -> Verification {
        guard try await BrightSpaceCredentialStore.load(userID: binderUUID, on: db) != nil else {
            throw BindError.binderNotConnected
        }

        // The binder becomes the course's sync identity, then the org unit is
        // verified using their (now course-resolved) key.
        course.brightspaceOrgUnitID = orgUnitID
        course.brightspaceSyncUserID = binderUUID
        course.brightspaceOrgUnitName = nil
        try await course.save(on: db)

        guard let client = try await application.brightSpaceClient(forCourse: course) else {
            return .unverified
        }
        do {
            guard let info = try await client.getOrgUnit(orgUnitID: orgUnitID, on: application) else {
                return .notFound
            }
            course.brightspaceOrgUnitName = info.name
            try await course.save(on: db)
            return .verified(name: info.name)
        } catch {
            application.logger.warning("BrightSpace org-unit verification failed for \(orgUnitID): \(error)")
            return .failed(error.localizedDescription)
        }
    }

    /// Maps unmapped assignments to D2L grade items whose name matches the
    /// assignment title (trimmed, case-insensitive). Only fills empty
    /// mappings — never overrides an existing one — so it is safe to re-run.
    /// Returns how many assignments were mapped. Throws when the grade book
    /// cannot be read.
    static func autoMap(
        courseUUID: UUID,
        orgUnitID: String,
        client: BrightSpaceAPIClient,
        on db: Database,
        application: Application
    ) async throws -> Int {
        let gradeObjects = try await client.listGradeObjects(orgUnitID: orgUnitID, on: application)

        // Index grade items by normalized name; first wins if D2L has duplicates.
        var idByName: [String: String] = [:]
        for object in gradeObjects {
            let key = object.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if !key.isEmpty, idByName[key] == nil { idByName[key] = object.id }
        }

        let assignments = try await APIAssignment.query(on: db)
            .filter(\.$courseID == courseUUID)
            .all()
        var mapped = 0
        for assignment in assignments where (assignment.brightspaceGradeObjectID ?? "").isEmpty {
            let key = assignment.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if let objectID = idByName[key] {
                assignment.brightspaceGradeObjectID = objectID
                try await assignment.save(on: db)
                mapped += 1
            }
        }
        return mapped
    }
}
