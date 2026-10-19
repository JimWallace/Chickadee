// APIServer/Helpers/ClassGoalBonusTable.swift
//
// Every student's class-goal bonus on one assignment, for the grades CSV,
// which reads the whole roster at once. It reads the snapshots and, for an
// activity that runs per lab group, each student's lab once per assignment,
// not once per student (docs/lab-groups.md, slice 5).

import Core
import Fluent
import Foundation

struct ClassGoalBonusTable {
    private let goals: [Achievement]
    /// The class's snapshots: for an activity that runs per lab group, those
    /// of the goals not counted per lab.
    private let classSnapshots: [String: any ClassGoalSnapshot]
    private let labByStudent: [UUID: UUID]
    private let snapshotsByLab: [UUID: [String: any ClassGoalSnapshot]]

    /// The table for `assignment`, or nil when its manifest carries no class
    /// goal.
    static func load(
        assignment: APIAssignment, props: TestProperties?, on db: any Database
    ) async throws -> ClassGoalBonusTable? {
        guard let props else { return nil }
        let goals = props.achievements.filter(\.isClassGoal)
        guard !goals.isEmpty else { return nil }
        let setupID = assignment.testSetupID
        let classSnapshots = try await LabGoalGroups.classSnapshots(testSetupID: setupID, props: props, on: db)
        guard props.activity?.isPerGroup == true else {
            return ClassGoalBonusTable(
                goals: goals, classSnapshots: classSnapshots, labByStudent: [:], snapshotsByLab: [:])
        }
        return ClassGoalBonusTable(
            goals: goals, classSnapshots: classSnapshots,
            labByStudent: try await LabGoalGroups.byStudent(assignment: assignment, on: db),
            snapshotsByLab: try await LabGoalGroups.snapshotsByLab(testSetupID: setupID, on: db))
    }

    /// The bonus points `userID` earns: from the class's snapshots and, on an
    /// activity that runs per lab group, their lab's.
    func points(for userID: UUID) -> Double {
        var snapshots = classSnapshots
        if let lab = labByStudent[userID], let labSnapshots = snapshotsByLab[lab] {
            snapshots.merge(labSnapshots) { _, lab in lab }
        }
        return classGoalBonusPoints(goals: goals, snapshots: snapshots)
    }
}
