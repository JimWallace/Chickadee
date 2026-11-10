// APIServer/Migrations/BackfillAssignmentType.swift
//
// One-time backfill: records a declared `AssignmentType` for every assignment
// that has none (docs/assignment-types.md, "Backfill"). The type comes from
// the assignment's manifest through `AssignmentType.derivedDeclaration`:
// browser grading means a Lab, otherwise an activity block means a Class
// activity, otherwise an Assignment. Never the title.
//
// A setup whose manifest is missing or does not decode is recorded as an
// Assignment, the safe direction. A row that already has a type keeps it. On
// a fresh database it touches no rows.

import Core
import Fluent
import Foundation

struct BackfillAssignmentType: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        let assignments = try await APIAssignment.query(on: database)
            .filter(\.$assignmentTypeRaw == nil)
            .all()
        guard !assignments.isEmpty else { return }
        let setupIDs = Array(Set(assignments.map(\.testSetupID)))
        let setups = try await APITestSetup.query(on: database)
            .filter(\.$id ~~ setupIDs)
            .all()
        let derived = Dictionary(
            setups.compactMap { setup in setup.id.map { ($0, setup.derivedAssignmentType) } },
            uniquingKeysWith: { first, _ in first })
        var counts: [AssignmentType: Int] = [:]
        for assignment in assignments {
            let type = derived[assignment.testSetupID] ?? .assignment
            assignment.assignmentType = type
            try await assignment.save(on: database)
            counts[type, default: 0] += 1
        }
        let summary = AssignmentType.allCases.map { "\($0.rawValue)=\(counts[$0, default: 0])" }
            .joined(separator: " ")
        database.logger.info("assignment_type_backfilled \(summary)")
    }

    /// Nothing to undo: `AddAssignmentType.revert` drops the column.
    func revert(on database: any Database) async throws {}
}
