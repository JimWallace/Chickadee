// APIServer/Services/LearnSectionSyncService.swift
//
// Periodic sweep that maps each enrolled student to their LEARN group name
// (e.g. "Lab 3") by fetching the course's configured D2L group category and
// walking its groups' member lists.
//
// The sweep only runs for courses that have:
//   1. A `brightspaceOrgUnitID` (bound to a LEARN org unit)
//   2. A `brightspaceSectionCategoryID` (the D2L group category ID for sections)
//
// The per-student result is stored on `APICourseEnrollment.brightspaceSection`
// (nil if the student is not in any group in that category).  Nothing here
// touches grades or roster readiness — it is an independent signal layer.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - Helpers

/// Builds two lookup maps from a classlist: orgDefinedID→D2LUserID and username→D2LUserID.
private func classlistIdentityMaps(
    _ classlist: [BrightSpaceClasslistEntry]
) -> (byOrgDefinedId: [String: String], byUsername: [String: String]) {
    var byOrgDefinedId: [String: String] = [:]
    var byUsername: [String: String] = [:]
    for entry in classlist {
        guard let uid = entry.userID, !uid.isEmpty else { continue }
        if let oid = entry.orgDefinedID, !oid.isEmpty {
            byOrgDefinedId[oid.lowercased()] = uid
        }
        if let uname = entry.username, !uname.isEmpty {
            byUsername[uname.lowercased()] = uid
        }
    }
    return (byOrgDefinedId, byUsername)
}

// MARK: - Core reconciler

/// Outcome counts for one course's section-sync pass.
struct SectionSyncOutcome: Sendable {
    var checked = 0
    var assigned = 0
    var cleared = 0
    var updated = 0
}

/// Syncs section membership for one course: fetches the configured group
/// category's groups, maps each member's D2L user ID to an enrolled student
/// via the classlist, and persists `brightspaceSection` on their enrollment.
///
/// Students not found in any group have their `brightspaceSection` cleared.
@discardableResult
func syncCourseSections(
    course: APICourse,
    orgUnitID: String,
    categoryID: String,
    client: any BrightSpaceGrading,
    on db: Database,
    application: Application
) async throws -> SectionSyncOutcome {
    guard let courseID = course.id else { return SectionSyncOutcome() }

    // Fetch classlist and groups in parallel — independent D2L calls.
    async let classlistTask = client.fetchClasslist(orgUnitID: orgUnitID, on: application)
    async let groupsTask = client.fetchGroups(
        orgUnitID: orgUnitID, categoryID: categoryID, on: application)
    let (classlist, groups) = try await (classlistTask, groupsTask)

    // Build D2L user ID → classlist identity mapping.
    var classlistByD2LUserID: [String: BrightSpaceClasslistEntry] = [:]
    for entry in classlist {
        if let uid = entry.userID, !uid.isEmpty {
            classlistByD2LUserID[uid] = entry
        }
    }

    // Build D2L user ID → section name mapping from groups.
    var sectionByD2LUserID: [String: String] = [:]
    for group in groups {
        for d2lUserID in group.enrollments {
            sectionByD2LUserID[d2lUserID] = group.name
        }
    }

    // Load enrolled students and their users.
    let enrollments = try await APICourseEnrollment.query(on: db)
        .filter(\.$course.$id == courseID)
        .all()
    let studentEnrollments = enrollments.filter { $0.role == .student }
    guard !studentEnrollments.isEmpty else { return SectionSyncOutcome() }

    let userIDs = studentEnrollments.map(\.userID)
    let users = try await APIUser.query(on: db)
        .filter(\.$id ~~ userIDs)
        .all()

    // Build identity lookup: (orgDefinedId or username) → D2L user ID,
    // using the classlist as the bridge.
    let (d2lUserIDByOrgDefinedId, d2lUserIDByUsername) = classlistIdentityMaps(classlist)

    var userByID: [UUID: APIUser] = [:]
    for user in users {
        if let id = user.id { userByID[id] = user }
    }

    var outcome = SectionSyncOutcome()
    for enrollment in studentEnrollments {
        guard let student = userByID[enrollment.userID] else { continue }
        outcome.checked += 1

        // Resolve D2L user ID for this student via classlist identity match.
        let d2lUserID =
            student.studentID.flatMap { d2lUserIDByOrgDefinedId[$0.lowercased()] }
            ?? d2lUserIDByUsername[student.username.lowercased()]

        let section = d2lUserID.flatMap { sectionByD2LUserID[$0] }

        let changed = enrollment.brightspaceSection != section
        if changed {
            enrollment.brightspaceSection = section
            try await enrollment.save(on: db)
            outcome.updated += 1
        }
        if section != nil { outcome.assigned += 1 } else { outcome.cleared += 1 }
    }
    return outcome
}

// MARK: - Sweep (all courses)

/// Sweeps every BrightSpace-bound course that has a section category configured.
/// Returns the total number of enrollment rows updated across all courses.
@discardableResult
func sweepLearnSections(
    on db: Database,
    resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
    logger: Logger,
    application: Application
) async throws -> Int {
    let courses = try await APICourse.query(on: db).all()
    var totalUpdated = 0
    for course in courses {
        guard
            let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty,
            let categoryID = course.brightspaceSectionCategoryID, !categoryID.isEmpty
        else { continue }

        let client: (any BrightSpaceGrading)?
        do {
            client = try await resolveClient(course)
        } catch {
            logger.warning(
                "Section sync: client resolve failed for course \(course.code): \(error)")
            continue
        }
        guard let client else { continue }

        do {
            let outcome = try await syncCourseSections(
                course: course, orgUnitID: orgUnitID, categoryID: categoryID,
                client: client, on: db, application: application)
            totalUpdated += outcome.updated
            if outcome.updated > 0 {
                logger.info(
                    "Section sync for \(course.code): "
                        + "\(outcome.assigned) assigned, \(outcome.cleared) cleared "
                        + "(\(outcome.updated) changed)")
            }
        } catch {
            logger.warning("Section sync failed for course \(course.code): \(error)")
        }
    }
    return totalUpdated
}

// MARK: - Monitor

/// Section sync cadence: 10 minutes, matching the roster-readiness sweep.
/// Group membership changes infrequently; a 10-minute window is fast enough
/// to catch manual reassignments without hammering D2L.
private let learnSectionSyncInterval: TimeInterval = 10 * 60

struct LearnSectionSyncMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var learnSectionSyncMonitor: PeriodicSweepMonitor {
        get {
            if let existing = storage[LearnSectionSyncMonitorKey.self] { return existing }
            let created = PeriodicSweepMonitor(
                name: "LEARN section sync",
                interval: learnSectionSyncInterval,
                runImmediately: false
            ) { application in
                guard application.brightSpaceAppCredentials != nil else { return }
                _ = try await sweepLearnSections(
                    on: application.db,
                    resolveClient: { course in
                        try await application.brightSpaceClient(forCourse: course)
                    },
                    logger: application.logger,
                    application: application
                )
            }
            storage[LearnSectionSyncMonitorKey.self] = created
            return created
        }
        set { storage[LearnSectionSyncMonitorKey.self] = newValue }
    }
}
