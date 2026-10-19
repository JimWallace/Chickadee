// APIServer/Services/LabGoalGroups.swift
//
// Which lab group a student's class goal is counted in, for an activity that
// runs once per lab group (docs/lab-groups.md, slice 5). One rule serves the
// sweep and every grade path, so a student counts in one lab only: the group
// of the session they joined most recently (a removed join, a join after the
// deadline and a removed lab do not count), else the group they are a member
// of. A student with neither is in no lab and earns no lab bonus.
//
// `LeaderboardGroupScope.studentGroup` picks the board a student sees. It
// reads the same join first, then a group the student ranked in; ranking
// needs a join, so the two agree.

import Core
import Fluent
import Foundation

enum LabGoalGroups {

    /// True for a goal counted per lab: a grade goal or a goal with no
    /// condition. An `itemsCovered` or a `classCoverage` goal is still counted
    /// for the whole class until slices 5b and 5c.
    static func isCountedPerLab(_ goal: Achievement) -> Bool {
        !goal.isUnionClassGoal && !goal.isCoverageClassGoal
    }

    /// Each student's lab for the assignment's class goals, for every student
    /// who joined one of its sessions or is a member of a group. Callers keep
    /// only the students enrolled now.
    static func byStudent(assignment: APIAssignment, on db: any Database) async throws -> [UUID: UUID] {
        try await resolve(assignment: assignment, onlyUserID: nil, on: db)
    }

    /// One student's lab, or nil. It reads only that student's rows.
    static func lab(of userID: UUID, assignment: APIAssignment, on db: any Database) async throws -> UUID? {
        try await resolve(assignment: assignment, onlyUserID: userID, on: db)[userID]
    }

    /// The rule. Only an active lab counts, so a student of a removed lab
    /// falls back to another. Only a join up to the deadline counts, so a
    /// student's lab, and with it their bonus, cannot move after the goal
    /// freezes. A student with a grade joined a session, so membership
    /// decides only for a student with no grade.
    private static func resolve(
        assignment: APIAssignment, onlyUserID: UUID?, on db: any Database
    ) async throws -> [UUID: UUID] {
        guard let assignmentID = assignment.id,
            let setID = try await CourseGroupStore.sets(courseID: assignment.courseID, on: db).first?.id
        else { return [:] }
        let active = Set(try await CourseGroupStore.groups(inSet: setID, on: db).compactMap(\.id))
        let memberships = APICourseGroupMembership.query(on: db).filter(\.$setID == setID)
        if let onlyUserID { memberships.filter(\.$userID == onlyUserID) }
        var lab: [UUID: UUID] = [:]
        for row in try await memberships.all() where active.contains(row.groupID) {
            lab[row.userID] = row.groupID
        }
        let groupBySession = Dictionary(
            try await ActivitySessionStore.sessions(assignmentID: assignmentID, on: db).compactMap { session in
                active.contains(session.groupID) ? session.id.map { ($0, session.groupID) } : nil
            },
            uniquingKeysWith: { first, _ in first })
        guard !groupBySession.isEmpty else { return lab }
        let joins = APIActivitySessionAttendance.query(on: db)
            .filter(\.$sessionID ~~ Array(groupBySession.keys))
            .filter(\.$removedAt == nil)
        if let onlyUserID { joins.filter(\.$userID == onlyUserID) }
        if let dueAt = assignment.dueAt { joins.filter(\.$joinedAt <= dueAt) }
        // Oldest first, so the latest join is the one that stays.
        for join in try await joins.sort(\.$joinedAt).all() {
            if let groupID = groupBySession[join.sessionID] { lab[join.userID] = groupID }
        }
        return lab
    }

    /// The class-goal snapshots that apply to `userID`, by achievement. For an
    /// activity that runs per lab group, a goal counted per lab reads the
    /// student's lab, and has no snapshot for a student in no lab; every
    /// other goal reads the class's.
    static func snapshots(
        testSetupID: String, props: TestProperties, userID: UUID?, on db: any Database
    ) async throws -> [String: any ClassGoalSnapshot] {
        var rows = try await classSnapshots(testSetupID: testSetupID, props: props, on: db)
        guard props.activity?.isPerGroup == true, let userID,
            let assignment = try await APIAssignment.query(on: db).filter(\.$testSetupID == testSetupID).first(),
            let groupID = try await lab(of: userID, assignment: assignment, on: db)
        else { return rows }
        let labRows = try await APIGroupAchievementResult.query(on: db)
            .filter(\.$testSetupID == testSetupID)
            .filter(\.$groupID == groupID)
            .all()
        for row in labRows { rows[row.achievementID] = row }
        return rows
    }

    /// The class's snapshots, by achievement. For an activity that runs per
    /// lab group, without the goals counted per lab.
    static func classSnapshots(
        testSetupID: String, props: TestProperties, on db: any Database
    ) async throws -> [String: any ClassGoalSnapshot] {
        let rows = byAchievement(
            try await APIAchievementResult.query(on: db).filter(\.$testSetupID == testSetupID).all())
        guard props.activity?.isPerGroup == true else { return rows }
        let perLab = Set(props.achievements.filter(isCountedPerLab).map(\.id))
        return rows.filter { !perLab.contains($0.key) }
    }

    /// Every lab's snapshots, by lab and then by achievement.
    static func snapshotsByLab(
        testSetupID: String, on db: any Database
    ) async throws -> [UUID: [String: any ClassGoalSnapshot]] {
        let rows = try await APIGroupAchievementResult.query(on: db).filter(\.$testSetupID == testSetupID).all()
        return Dictionary(grouping: rows, by: \.groupID).mapValues(byAchievement)
    }

    /// Deletes every class-goal snapshot of the setups: the class's and each
    /// lab's.
    static func deleteSnapshots(forTestSetups setupIDs: [String], on db: any Database) async throws {
        try await APIAchievementResult.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
        try await APIGroupAchievementResult.query(on: db).filter(\.$testSetupID ~~ setupIDs).delete()
    }

    private static func byAchievement(_ rows: [any ClassGoalSnapshot]) -> [String: any ClassGoalSnapshot] {
        Dictionary(rows.map { ($0.achievementID, $0) }, uniquingKeysWith: { first, _ in first })
    }
}
