// APIServer/Services/CourseSectionService.swift
//
// The validation and the writes for course sections, shared by the web routes
// (`CourseAdminRoutes+Sections.swift`) and the MCP tools
// (`CourseSectionTools.swift`) (#2769). Each surface wrote them once, and they
// drifted: the web checked the grading mode against string literals, while MCP
// checked it against `GradingMode`. A section now carries neither a grading
// mode nor a default type, only a name (docs/assignment-types.md).
//
// Authorization stays at each surface, and so does the section lookup for a
// move (the web ignores a section in another course, and MCP refuses it). A
// surface authorizes, builds a draft or an edit, and calls the service. It maps
// a `CourseSectionError` to its own error type.

import Core
import Fluent
import Foundation

/// A validated new course section. The initializer holds every rule, so a
/// draft that exists is valid.
struct CourseSectionDraft: Sendable {
    let name: String

    init(name: String) throws(CourseSectionError) {
        self.name = try CourseSectionService.validatedName(name)
    }
}

/// A validated rename of a course section, its only editable field.
struct CourseSectionEdit: Sendable {
    let name: String

    init(name: String) throws(CourseSectionError) {
        self.name = try CourseSectionService.validatedName(name)
    }
}

/// What a move of an assignment into a section did.
struct CourseSectionMoveResult: Sendable {
    /// The section the assignment is now in; nil when ungrouped.
    let section: APICourseSection?
    /// The assignment's grading mode, which a move never changes; nil when
    /// it has no setup.
    let gradingMode: String?
}

enum CourseSectionService {

    // MARK: - Field rules

    /// The trimmed name. An empty name is refused.
    static func validatedName(_ raw: String) throws(CourseSectionError) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .emptyName }
        return name
    }

    // MARK: - Writes

    /// Saves a new section after the course's existing ones. The caller has
    /// authorized the write to `courseID`.
    static func create(
        _ draft: CourseSectionDraft, courseID: UUID, on db: any Database
    ) async throws -> APICourseSection {
        let maxOrder =
            try await APICourseSection.query(on: db)
            .filter(\.$courseID == courseID)
            .max(\.$sortOrder) ?? 0
        let section = APICourseSection(name: draft.name, sortOrder: maxOrder + 1, courseID: courseID)
        try await section.save(on: db)
        return section
    }

    /// Applies `edit` to the section and saves it.
    static func update(
        _ section: APICourseSection, with edit: CourseSectionEdit, on db: any Database
    ) async throws {
        section.name = edit.name
        try await section.save(on: db)
    }

    /// Deletes the section and returns how many assignments it ungrouped. The
    /// foreign key is SET NULL, so its assignments stay and lose the link.
    @discardableResult
    static func delete(_ section: APICourseSection, on db: any Database) async throws -> Int {
        let sectionID = try section.requireID()
        let ungrouped = try await APIAssignment.query(on: db)
            .filter(\.$sectionID == sectionID)
            .count()
        try await section.delete(on: db)
        return ungrouped
    }

    /// Moves an assignment to the end of `sectionID`'s lane (nil = ungrouped)
    /// and saves it. The content items attached to the assignment take its new
    /// section in the same transaction, as `CourseContentService.attach` sets
    /// it; their `sortOrder` stays, because they are not section items. The
    /// caller has authorized the write and resolved `sectionID` in the
    /// assignment's course.
    ///
    /// A move changes neither the declared type nor the grading mode
    /// (docs/assignment-types.md, phase 3). Before phase 3 a move adopted the
    /// section's default grading mode, so an Assignment dragged into a
    /// browser-default section shipped its secret tests to every student.
    @discardableResult
    static func moveAssignment(
        _ assignment: APIAssignment, toSection sectionID: UUID?, on db: any Database
    ) async throws -> CourseSectionMoveResult {
        let assignmentID = try assignment.requireID()
        try await db.transaction { tx in
            assignment.sectionID = sectionID
            // Append to the destination lane's shared (assignment + content)
            // order so the moved assignment does not collide with an existing
            // sort_order.
            assignment.sortOrder = try await nextSectionItemSortOrder(
                courseID: assignment.courseID, sectionID: sectionID, db: tx)
            try await assignment.save(on: tx)
            try await APICourseContentItem.query(on: tx)
                .filter(\.$assignmentID == assignmentID)
                .set(\.$sectionID, to: sectionID)
                .update()
        }

        let section: APICourseSection? =
            if let sectionID { try await APICourseSection.find(sectionID, on: db) } else { nil }
        let setup = try await APITestSetup.find(assignment.testSetupID, on: db)
        return CourseSectionMoveResult(
            section: section, gradingMode: setup.map { currentManifestGradingMode($0.manifest) })
    }
}
