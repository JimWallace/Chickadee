// APIServer/Services/CourseSectionService.swift
//
// The validation and the writes for course sections, shared by the web routes
// (`CourseAdminRoutes+Sections.swift`) and the MCP tools
// (`CourseSectionTools.swift`) (#2769). Each surface wrote them once, and they
// drifted: the web checked the grading mode against string literals, while MCP
// checked it against `GradingMode`. A section now carries an optional default
// assignment type instead of a grading mode (docs/assignment-types.md).
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
    let defaultAssignmentType: AssignmentType?

    /// `defaultAssignmentType` nil or "" means no default.
    init(name: String, defaultAssignmentType: String?) throws(CourseSectionError) {
        self.name = try CourseSectionService.validatedName(name)
        self.defaultAssignmentType = try defaultAssignmentType.flatMap(CourseSectionService.parseDefaultType)
    }
}

/// A validated change to a course section. A nil field is left unchanged.
struct CourseSectionEdit: Sendable {
    let name: String?
    /// Nil leaves the default unchanged; `.some(nil)` clears it.
    let defaultAssignmentType: AssignmentType??

    /// `defaultAssignmentType` nil leaves it unchanged, and "" clears it.
    init(name: String?, defaultAssignmentType: String?) throws(CourseSectionError) {
        self.name = try name.map(CourseSectionService.validatedName)
        self.defaultAssignmentType = try defaultAssignmentType.map(CourseSectionService.parseDefaultType)
    }
}

/// What a move of an assignment into a section did.
struct CourseSectionMoveResult: Sendable {
    /// The section the assignment is now in; nil when ungrouped.
    let section: APICourseSection?
    /// The assignment's grading mode, which a move never changes; nil when
    /// it has no setup.
    let gradingMode: String?
    /// Set when the section's default type differs from the assignment's
    /// declared type. A move changes neither, so this only says so
    /// (docs/assignment-types.md).
    let typeNote: String?
}

enum CourseSectionService {

    // MARK: - Field rules

    /// The trimmed name. An empty name is refused.
    static func validatedName(_ raw: String) throws(CourseSectionError) -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw .emptyName }
        return name
    }

    /// The default type for `raw`: nil for an empty string (no default), and
    /// a value that is not an `AssignmentType` is refused.
    static func parseDefaultType(_ raw: String) throws(CourseSectionError) -> AssignmentType? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        guard let type = AssignmentType(rawValue: trimmed) else { throw .unknownAssignmentType(raw) }
        return type
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
            name: draft.name, defaultAssignmentType: draft.defaultAssignmentType,
            sortOrder: maxOrder + 1, courseID: courseID)
        try await section.save(on: db)
        return section
    }

    /// Applies `edit` to the section and saves it.
    static func update(
        _ section: APICourseSection, with edit: CourseSectionEdit, on db: any Database
    ) async throws {
        if let name = edit.name { section.name = name }
        if let type = edit.defaultAssignmentType { section.defaultAssignmentType = type }
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
    /// and saves it. The caller has authorized the write and resolved
    /// `sectionID` in the assignment's course.
    ///
    /// A move changes neither the declared type nor the grading mode
    /// (docs/assignment-types.md, phase 3). Before phase 3 a move adopted the
    /// section's default grading mode, so an Assignment dragged into a
    /// browser-default section shipped its secret tests to every student.
    /// When the section's default type differs from the assignment's, the
    /// result says so, so the author can change the type deliberately.
    @discardableResult
    static func moveAssignment(
        _ assignment: APIAssignment, toSection sectionID: UUID?, on db: any Database
    ) async throws -> CourseSectionMoveResult {
        assignment.sectionID = sectionID
        // Append to the destination lane's shared (assignment + content) order
        // so the moved assignment does not collide with an existing sort_order.
        assignment.sortOrder = try await nextSectionItemSortOrder(
            courseID: assignment.courseID, sectionID: sectionID, db: db)
        try await assignment.save(on: db)

        let section: APICourseSection? =
            if let sectionID { try await APICourseSection.find(sectionID, on: db) } else { nil }
        let setup = try await APITestSetup.find(assignment.testSetupID, on: db)
        return CourseSectionMoveResult(
            section: section, gradingMode: setup.map { currentManifestGradingMode($0.manifest) },
            typeNote: section.flatMap { typeNote(for: assignment, in: $0) })
    }

    /// The sentence a move reports when `section` names a default type that
    /// `assignment` does not declare, or nil.
    static func typeNote(for assignment: APIAssignment, in section: APICourseSection) -> String? {
        guard let sectionType = section.defaultAssignmentType, sectionType != assignment.assignmentType else {
            return nil
        }
        return "\(assignment.title) stays \(assignment.assignmentType.withArticle), though "
            + "\(section.name) defaults to \(sectionType.withArticle); change the type on its edit page "
            + "if needed."
    }
}
