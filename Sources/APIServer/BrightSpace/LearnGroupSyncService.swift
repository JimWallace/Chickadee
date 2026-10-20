// APIServer/BrightSpace/LearnGroupSyncService.swift
//
// The periodic sweep that reads each synced group set from LEARN
// (docs/lab-groups.md, slice 6). A `learnSections` set reads the D2L Sections
// of the course offering, the source the UW labs come from; a `learnGroups`
// set reads the D2L group category its external ID names. The classlist maps
// each member's D2L user ID to a student of the course, and
// `CourseGroupStore.applySync` writes the groups and the memberships.
//
// The sweep only reads a course that is not archived and is bound to a LEARN
// org unit. Nothing here touches grades or roster readiness.

import Core
import Fluent
import Foundation
import Vapor

// MARK: - One set

/// Reads one synced set from LEARN and writes it through the store. A
/// student the classlist cannot match, and one in no LEARN group, ends in no
/// group. A student in two LEARN groups of the set is placed in the first
/// that LEARN lists. Returns nil for a set that LEARN does not sync, and for
/// an empty group list or classlist, which changes nothing: a course whose
/// labs or students all vanish at once is far more likely a LEARN fault than
/// a real change.
@discardableResult
func syncLearnGroupSet(
    _ set: APICourseGroupSet,
    orgUnitID: String,
    client: any BrightSpaceGrading,
    on db: any Database,
    application: Application,
    now: Date = Date()
) async throws -> CourseGroupStore.SyncResult? {
    let remote: [BrightSpaceGroup]
    switch set.source {
    case .learnSections:
        remote = try await client.fetchSections(orgUnitID: orgUnitID, on: application)
    case .learnGroups:
        guard let categoryID = set.externalID, !categoryID.isEmpty else { return nil }
        remote = try await client.fetchGroups(orgUnitID: orgUnitID, categoryID: categoryID, on: application)
    case .manual, nil:
        return nil
    }
    guard !remote.isEmpty else { return nil }
    let classlist = try await client.fetchClasslist(orgUnitID: orgUnitID, on: application)
    guard !classlist.isEmpty else { return nil }
    let identityIndex = BrightSpaceIdentityIndex(classlist: classlist)

    var groupByD2LUserID: [String: String] = [:]
    for group in remote {
        for d2lUserID in group.enrollments where groupByD2LUserID[d2lUserID] == nil {
            groupByD2LUserID[d2lUserID] = group.groupID
        }
    }
    let studentIDs = try await CourseRoster.studentIDs(in: set.courseID, on: db)
    let students = try await APIUser.query(on: db).filter(\.$id ~~ Array(studentIDs)).all()
    var members: [UUID: String] = [:]
    for student in students {
        guard let userID = student.id,
            let d2lUserID = identityIndex.d2lUserID(username: student.username, studentID: student.studentID),
            let groupID = groupByD2LUserID[d2lUserID]
        else { continue }
        members[userID] = groupID
    }
    return try await CourseGroupStore.applySync(
        remote.map { CourseGroupStore.SyncedGroup(externalID: $0.groupID, name: $0.name) },
        members: members, to: set, now: now, on: db)
}

// MARK: - Sweep (all courses)

/// Syncs every set that LEARN syncs, in each course that is not archived and
/// is bound to a LEARN org unit. A set that fails is logged and skipped.
/// Returns the number of sets synced.
@discardableResult
func sweepLearnGroups(
    on db: any Database,
    resolveClient: (APICourse) async throws -> (any BrightSpaceGrading)?,
    logger: Logger,
    application: Application
) async throws -> Int {
    let sets = try await APICourseGroupSet.query(on: db)
        .filter(\.$sourceRaw != CourseGroupSource.manual.rawValue)
        .all()
    var synced = 0
    for set in sets {
        guard let course = try await APICourse.find(set.courseID, on: db), !course.isArchived,
            let orgUnitID = course.brightspaceOrgUnitID, !orgUnitID.isEmpty
        else { continue }
        do {
            guard let client = try await resolveClient(course),
                let result = try await syncLearnGroupSet(
                    set, orgUnitID: orgUnitID, client: client, on: db, application: application)
            else { continue }
            synced += 1
            if result.added + result.renamed + result.removed > 0 {
                logger.info(
                    "LEARN group sync for \(course.code): \(result.placed) placed, \(result.added) groups added or restored, \(result.renamed) renamed, \(result.removed) removed"
                )
            }
        } catch {
            logger.warning("LEARN group sync failed for course \(course.code): \(error)")
        }
    }
    return synced
}

// MARK: - Monitor

/// Group sync cadence: 10 minutes, matching the roster-readiness sweep.
/// Membership changes infrequently; a 10-minute window is fast enough to
/// catch a moved student without hammering D2L.
private let learnGroupSyncInterval: TimeInterval = 10 * 60

struct LearnGroupSyncMonitorKey: StorageKey {
    typealias Value = PeriodicSweepMonitor
}

extension Application {
    var learnGroupSyncMonitor: PeriodicSweepMonitor {
        lazyStored(LearnGroupSyncMonitorKey.self) {
            PeriodicSweepMonitor(
                name: "LEARN group sync",
                interval: learnGroupSyncInterval
            ) { application in
                guard application.brightSpaceAppCredentials != nil else { return }
                _ = try await sweepLearnGroups(
                    on: application.db,
                    resolveClient: { course in
                        try await application.brightSpaceClient(forCourse: course)
                    },
                    logger: application.logger,
                    application: application
                )
            }
        }
    }
}
