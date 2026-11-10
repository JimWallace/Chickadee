// APIServer/Services/CourseSectionService.swift
//
// The validation and the writes for course sections, shared by the web routes
// (`CourseAdminRoutes+Sections.swift`) and the MCP tools
// (`CourseSectionTools.swift`) (#2769). Each surface wrote them once, and they
// drifted: the web checked the grading mode against string literals, while MCP
// checked it against `GradingMode`.
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
    let defaultGradingMode: GradingMode

    init(name: String, defaultGradingMode: String) throws(CourseSectionError) {
        self.name = try CourseSectionService.validatedName(name)
        self.defaultGradingMode = try CourseSectionService.parseGradingMode(defaultGradingMode)
    }
}

/// A validated change to a course section. A nil field is left unchanged.
struct CourseSectionEdit: Sendable {
    let name: String?
    let defaultGradingMode: GradingMode?

    init(name: String?, defaultGradingMode: String?) throws(CourseSectionError) {
        self.name = try name.map(CourseSectionService.validatedName)
        self.defaultGradingMode = try defaultGradingMode.map(CourseSectionService.parseGradingMode)
    }
}

/// What a move of an assignment into a section did.
struct CourseSectionMoveResult: Sendable {
    /// The section the assignment is now in; nil when ungrouped.
    let section: APICourseSection?
    /// The assignment's grading mode after the move; nil when it has no setup.
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

    /// The grading mode for `raw`. A value that is not a `GradingMode` is
    /// refused.
    static func parseGradingMode(_ raw: String) throws(CourseSectionError) -> GradingMode {
        guard let mode = GradingMode(rawValue: raw) else { throw .unknownGradingMode(raw) }
        return mode
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
        let section = APICourseSection(
            name: draft.name, defaultGradingMode: draft.defaultGradingMode.rawValue,
            sortOrder: maxOrder + 1, courseID: courseID)
        try await section.save(on: db)
        return section
    }

    /// Applies `edit` to the section and saves it.
    static func update(
        _ section: APICourseSection, with edit: CourseSectionEdit, on db: any Database
    ) async throws {
        if let name = edit.name { section.name = name }
        if let mode = edit.defaultGradingMode { section.defaultGradingMode = mode.rawValue }
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
    /// and saves it. A move into a named section adopts that section's default
    /// grading mode where the manifest allows it (`adoptSectionGradingMode`).
    /// Ungrouping leaves the grading mode unchanged. The content items attached
    /// to the assignment take its new section in the same transaction, as
    /// `CourseContentService.attach` sets it; their `sortOrder` stays, because
    /// they are not section items. The caller has authorized the write and
    /// resolved `sectionID` in the assignment's course.
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
        guard let setup = try await APITestSetup.find(assignment.testSetupID, on: db) else {
            return CourseSectionMoveResult(section: section, gradingMode: nil)
        }
        let gradingMode =
            if let section {
                try await adoptSectionGradingMode(section, setup: setup, on: db)
            } else {
                currentManifestGradingMode(setup.manifest)
            }
        return CourseSectionMoveResult(section: section, gradingMode: gradingMode)
    }
}
