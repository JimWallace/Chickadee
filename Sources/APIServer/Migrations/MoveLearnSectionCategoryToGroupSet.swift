// APIServer/Migrations/MoveLearnSectionCategoryToGroupSet.swift
//
// The LEARN group sync reads group sets now (docs/lab-groups.md, slice 6).
// A course whose `brightspace_section_category_id` names a D2L group category,
// and that has no group set yet, gets one `learnGroups` set that reads that
// category. A course that has a set already keeps it: the lab features read
// the course's first set, and a second one would be read by nothing.
//
// The sync no longer writes the free-text `brightspace_section` name, so the
// old names are cleared rather than left to go stale.

import Fluent
import Foundation

struct MoveLearnSectionCategoryToGroupSet: ChickadeeMigration {
    func prepare(on database: any Database) async throws {
        let courses = try await APICourse.query(on: database)
            .filter(\.$brightspaceSectionCategoryID != nil)
            .all()
        for course in courses {
            let categoryID = course.brightspaceSectionCategoryID?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let courseID = course.id, !categoryID.isEmpty else { continue }
            let hasSet = try await APICourseGroupSet.query(on: database).filter(\.$courseID == courseID).count() > 0
            guard !hasSet else { continue }
            try await APICourseGroupSet(
                courseID: courseID, name: "LEARN groups", source: .learnGroups, externalID: categoryID
            ).save(on: database)
        }
        try await APICourseEnrollment.query(on: database)
            .filter(\.$brightspaceSection != nil)
            .set(\.$brightspaceSection, to: nil)
            .update()
    }

    /// Nothing to undo: the set is a group set like any other, and the names
    /// it cleared were a copy of LEARN's.
    func revert(on database: any Database) async throws {}
}
