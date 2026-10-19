// APIServer/Services/CourseGroupStore.swift
//
// Every read and write of a course's groups (docs/lab-groups.md, slice 1). The
// Groups tab, the roster's group select, the CSV import and the LEARN group
// sync (slice 6) write through here.
//
// Rules the store keeps:
//
//   * A person is in at most one group of a set. The database enforces it
//     with the unique key (set, user); `setMembership` replaces the row.
//   * Only a manual set is written by hand (`CourseGroupError.setNotEditable`),
//     and only a synced set is written by the LEARN sync (`setNotSynced`).
//   * A removed group keeps its row and loses its members.
//   * A membership names a person enrolled in the set's course when it is
//     written. A membership of a person who later leaves the course stays,
//     and every read that counts members counts enrolled students only.

import Core
import Fluent
import Foundation

enum CourseGroupStore {

    /// The longest set or group name.
    static let nameLimit = 80

    // MARK: - Reads

    /// The course's group sets, oldest first.
    static func sets(courseID: UUID, on db: any Database) async throws -> [APICourseGroupSet] {
        try await APICourseGroupSet.query(on: db)
            .filter(\.$courseID == courseID)
            .all()
            .sorted { ($0.createdAt ?? .distantPast, $0.name) < ($1.createdAt ?? .distantPast, $1.name) }
    }

    /// The set's groups in display order. Removed groups are left out unless
    /// `includingRemoved` is true.
    static func groups(
        inSet setID: UUID, includingRemoved: Bool = false, on db: any Database
    ) async throws -> [APICourseGroup] {
        var query = APICourseGroup.query(on: db).filter(\.$setID == setID)
        if !includingRemoved { query = query.filter(\.$removedAt == nil) }
        return try await query.all().sorted(by: displayOrder)
    }

    /// Each member's group in the set, by user id.
    static func groupIDsByUser(inSet setID: UUID, on db: any Database) async throws -> [UUID: UUID] {
        let rows = try await APICourseGroupMembership.query(on: db).filter(\.$setID == setID).all()
        return Dictionary(rows.map { ($0.userID, $0.groupID) }, uniquingKeysWith: { first, _ in first })
    }

    /// The ids of the students enrolled in `courseID` now.
    static func enrolledStudentIDs(courseID: UUID, on db: any Database) async throws -> Set<UUID> {
        let enrollments = try await APICourseEnrollment.query(on: db).filter(\.$course.$id == courseID).all()
        return Set(enrollments.filter { $0.role == .student }.map(\.userID))
    }

    // MARK: - Writes

    /// Creates a manual set in `courseID`.
    static func createSet(courseID: UUID, name: String, on db: any Database) async throws -> APICourseGroupSet {
        let set = APICourseGroupSet(courseID: courseID, name: try validName(name), source: .manual)
        try await set.save(on: db)
        return set
    }

    /// Adds a group at the end of a manual set. A name that an existing group
    /// of the set already has, in any letter case, is refused.
    static func addGroup(
        named name: String, to set: APICourseGroupSet, on db: any Database
    ) async throws
        -> APICourseGroup
    {
        try requireEditable(set)
        let setID = try set.requireID()
        let name = try validName(name)
        let existing = try await groups(inSet: setID, on: db)
        if existing.contains(where: { $0.name.lowercased() == name.lowercased() }) {
            throw CourseGroupError.duplicateGroupName(name)
        }
        let group = APICourseGroup(setID: setID, name: name, sortOrder: nextSortOrder(after: existing))
        try await group.save(on: db)
        return group
    }

    /// Removes a group of a manual set: the row stays, marked removed, and
    /// its members are in no group of the set.
    static func removeGroup(_ group: APICourseGroup, of set: APICourseGroupSet, on db: any Database) async throws {
        try requireEditable(set)
        guard group.setID == set.id else { throw CourseGroupError.groupNotInSet }
        guard group.removedAt == nil else { return }
        let now = Date()
        try await db.transaction { tx in try await markRemoved(group, now: now, on: tx) }
    }

    /// Puts one person in `groupID`, or in no group of the set when it is
    /// nil. The person must be enrolled in the set's course.
    static func setMembership(
        userID: UUID, groupID: UUID?, in set: APICourseGroupSet, on db: any Database
    ) async throws {
        try requireEditable(set)
        let setID = try set.requireID()
        let enrolled = try await APICourseEnrollment.query(on: db)
            .filter(\.$course.$id == set.courseID)
            .filter(\.$userID == userID)
            .first()
        guard enrolled != nil else { throw CourseGroupError.notEnrolled }
        if let groupID { try await requireActiveGroup(groupID, inSet: setID, on: db) }
        try await db.transaction { tx in
            try await APICourseGroupMembership.query(on: tx)
                .filter(\.$setID == setID)
                .filter(\.$userID == userID)
                .delete()
            if let groupID {
                try await APICourseGroupMembership(setID: setID, groupID: groupID, userID: userID).save(on: tx)
            }
        }
    }

    /// Replaces every membership of the set with `assignments` (user id to
    /// group id). A person absent from `assignments` ends in no group. The
    /// CSV import and the LEARN sweep both call this.
    static func replaceMemberships(
        in set: APICourseGroupSet, assignments: [UUID: UUID], on db: any Database
    ) async throws {
        let setID = try set.requireID()
        let active = Set(try await groups(inSet: setID, on: db).compactMap(\.id))
        guard assignments.values.allSatisfy(active.contains) else { throw CourseGroupError.groupNotInSet }
        try await db.transaction { tx in
            try await APICourseGroupMembership.query(on: tx).filter(\.$setID == setID).delete()
            for (userID, groupID) in assignments {
                try await APICourseGroupMembership(setID: setID, groupID: groupID, userID: userID).save(on: tx)
            }
        }
    }

    // MARK: - Import

    /// What an import did, for the message the Groups tab shows.
    struct ImportResult: Equatable, Sendable {
        /// Students placed in a group.
        let placed: Int
        /// The names of the groups the file made.
        let groupsCreated: [String]
        /// Usernames of the file that name no student of the course.
        let unmatched: [String]
    }

    /// Replaces the set's memberships with the students of `parsed`. A group
    /// name the set does not have yet is made. Names match in any letter
    /// case. A username that names no student of the course is reported and
    /// skipped.
    static func importRoster(
        _ parsed: GroupRosterCSV.Parsed, into set: APICourseGroupSet, on db: any Database
    ) async throws -> ImportResult {
        try requireEditable(set)
        let setID = try set.requireID()
        let studentIDs = try await enrolledStudentIDs(courseID: set.courseID, on: db)
        let students = try await APIUser.query(on: db).filter(\.$id ~~ Array(studentIDs)).all()
        let studentIDByUsername = Dictionary(
            students.compactMap { user in user.id.map { (user.username.lowercased(), $0) } },
            uniquingKeysWith: { first, _ in first })
        let unmatched = parsed.usernames.filter { studentIDByUsername[$0] == nil }

        let existing = try await groups(inSet: setID, on: db)
        let newNames = newGroupNames(parsed: parsed, matched: studentIDByUsername, existing: existing)
        return try await db.transaction { tx in
            var inSet = existing
            for name in newNames {
                let group = APICourseGroup(setID: setID, name: name, sortOrder: nextSortOrder(after: inSet))
                try await group.save(on: tx)
                inSet.append(group)
            }
            let groupIDByName = Dictionary(
                inSet.compactMap { group in group.id.map { (group.name.lowercased(), $0) } },
                uniquingKeysWith: { first, _ in first })
            var assignments: [UUID: UUID] = [:]
            for (username, groupName) in parsed.groupByUsername {
                guard let userID = studentIDByUsername[username],
                    let groupID = groupIDByName[groupName.lowercased()]
                else { continue }
                assignments[userID] = groupID
            }
            try await replaceMemberships(in: set, assignments: assignments, on: tx)
            return ImportResult(placed: assignments.count, groupsCreated: newNames, unmatched: unmatched)
        }
    }

    /// The group names the file needs that the set does not have, once each,
    /// in natural order ("Lab 2" before "Lab 10"). Only rows of matched
    /// students count, so a typo row does not make an empty group.
    private static func newGroupNames(
        parsed: GroupRosterCSV.Parsed, matched: [String: UUID], existing: [APICourseGroup]
    ) -> [String] {
        var known = Set(existing.map { $0.name.lowercased() })
        var names: [String] = []
        for username in parsed.usernames {
            guard matched[username] != nil, let name = parsed.groupByUsername[username] else { continue }
            if known.insert(name.lowercased()).inserted { names.append(name) }
        }
        return names.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    // MARK: - LEARN sync

    /// One group or section as LEARN lists it.
    struct SyncedGroup: Equatable, Sendable {
        let externalID: String
        let name: String
    }

    /// What a sync changed, for the log.
    struct SyncResult: Equatable, Sendable {
        /// Students placed in a group.
        var placed = 0
        /// Groups made, and removed groups that LEARN lists again.
        var added = 0
        var renamed = 0
        var removed = 0
    }

    /// Makes a synced set match LEARN: its groups match `remote` by external
    /// id, and each student of `members` (user id to the external id of their
    /// group) is in that group, and every other person in none. A new group
    /// goes at the end, a renamed one takes the new name, a removed one that
    /// LEARN lists again comes back, and one that LEARN no longer lists is
    /// removed as `removeGroup` removes it.
    static func applySync(
        _ remote: [SyncedGroup], members: [UUID: String], to set: APICourseGroupSet, now: Date,
        on db: any Database
    ) async throws -> SyncResult {
        guard !set.acceptsManualEdits else { throw CourseGroupError.setNotSynced }
        let setID = try set.requireID()
        let existing = try await groups(inSet: setID, includingRemoved: true, on: db)
        let byExternalID = Dictionary(
            existing.compactMap { group in group.externalID.map { ($0, group) } },
            uniquingKeysWith: { first, _ in first })
        let listed = Set(remote.map(\.externalID))
        let ordered = remote.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return try await db.transaction { tx in
            var result = SyncResult()
            var inSet = existing
            var groupIDByExternalID: [String: UUID] = [:]
            for item in ordered where groupIDByExternalID[item.externalID] == nil {
                let name = syncedName(item)
                let group: APICourseGroup
                if let known = byExternalID[item.externalID] {
                    group = known
                    if group.name != name {
                        group.name = name
                        result.renamed += 1
                    }
                    if group.removedAt != nil {
                        group.removedAt = nil
                        result.added += 1
                    }
                } else {
                    group = APICourseGroup(
                        setID: setID, name: name, sortOrder: nextSortOrder(after: inSet),
                        externalID: item.externalID)
                    inSet.append(group)
                    result.added += 1
                }
                try await group.save(on: tx)
                groupIDByExternalID[item.externalID] = try group.requireID()
            }
            let vanished = existing.filter { group in
                group.removedAt == nil && !(group.externalID.map(listed.contains) ?? false)
            }
            for group in vanished {
                try await markRemoved(group, now: now, on: tx)
                result.removed += 1
            }
            let assignments = members.compactMapValues { groupIDByExternalID[$0] }
            try await replaceMemberships(in: set, assignments: assignments, on: tx)
            set.lastSyncedAt = now
            try await set.save(on: tx)
            result.placed = assignments.count
            return result
        }
    }

    /// A LEARN name as a group name: trimmed and cut to `nameLimit`. A blank
    /// name falls back to the external id.
    private static func syncedName(_ group: SyncedGroup) -> String {
        let name = group.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? group.externalID : String(name.prefix(nameLimit))
    }

    // MARK: - Helpers

    /// Marks `group` removed: its members are in no group of the set, and its
    /// open sessions end with it, so no submission lands in a group nobody
    /// can see.
    private static func markRemoved(_ group: APICourseGroup, now: Date, on db: any Database) async throws {
        let groupID = try group.requireID()
        try await APICourseGroupMembership.query(on: db).filter(\.$groupID == groupID).delete()
        try await APIActivitySession.query(on: db)
            .filter(\.$groupID == groupID)
            .filter(\.$closedAt == nil)
            .set(\.$closedAt, to: now)
            .update()
        group.removedAt = now
        try await group.save(on: db)
    }

    private static func requireEditable(_ set: APICourseGroupSet) throws {
        guard set.acceptsManualEdits else { throw CourseGroupError.setNotEditable }
    }

    private static func requireActiveGroup(_ groupID: UUID, inSet setID: UUID, on db: any Database) async throws {
        guard let group = try await APICourseGroup.find(groupID, on: db), group.setID == setID else {
            throw CourseGroupError.groupNotInSet
        }
        guard group.removedAt == nil else { throw CourseGroupError.groupRemoved }
    }

    private static func validName(_ raw: String) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw CourseGroupError.blankName }
        guard name.count <= nameLimit else { throw CourseGroupError.nameTooLong(limit: nameLimit) }
        return name
    }

    private static func nextSortOrder(after groups: [APICourseGroup]) -> Int {
        (groups.map(\.sortOrder).max() ?? -1) + 1
    }

    private static func displayOrder(_ lhs: APICourseGroup, _ rhs: APICourseGroup) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }
}
