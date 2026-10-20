// APIServer/Services/SortOrderRenumbering.swift
//
// The one course-wide reorder (#2713). Four web routes and four MCP tools
// write a display order:
//
//   - course sections: POST /instructor/sections/reorder, reorder_course_sections
//   - section items:   POST /instructor/section-items/reorder,
//                      POST /instructor/reorder (assignments only),
//                      POST /instructor/content-items/reorder (content only),
//                      reorder_section_items, reorder_assignments,
//                      reorder_content_items
//
// Each one used to carry its own copy, and the copies disagreed on the role
// floor, on duplicate ids, on unknown types and on a partial list, and none
// used a transaction. Now each surface authorizes at `roleFloor`, parses its
// payload into `SortOrderItem`s or section ids, calls this service, and maps a
// `ReorderError` to its own error type.
//
// The rules:
//   - The role floor is `.ta` for every kind. Reordering is display
//     organization, not course lifecycle.
//   - A duplicate id, an unknown type and an id that names no item in the
//     course are refused.
//   - A course-section reorder names every section of the course. Sections
//     share one per-course sequence, so a partial list would leave two
//     sections at the same position.
//   - A section-item reorder names items of one course section (or only
//     ungrouped items), and renumbers them 1..n.
//   - All the writes of one reorder run in one transaction, so a failure
//     part-way leaves the old order.

import Core
import Fluent
import Foundation

enum SortOrderRenumbering {
    /// The role floor for every reorder kind, web and MCP.
    static let roleFloor: CourseRole = .ta

    /// Parses one course-section id.
    static func sectionID(_ raw: String) throws(ReorderError) -> UUID {
        guard let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .invalidID(raw)
        }
        return uuid
    }

    /// The courses that own `items`, for a web route that has no course in its
    /// path: it authorizes each course before it calls `renumberSectionItems`.
    /// An id that names no row adds no course.
    static func owningCourses(of items: [SortOrderItem], on db: any Database) async throws -> Set<UUID> {
        let (assignments, contentItems) = try await rows(for: items, inCourse: nil, on: db)
        return Set(assignments.map(\.courseID)).union(contentItems.map(\.courseID))
    }

    /// Writes `sort_order` 1..n onto `items`, in the given order, in one
    /// transaction. The caller has authorized `courseID` at `roleFloor`.
    static func renumberSectionItems(
        _ items: [SortOrderItem], inCourse courseID: UUID, on db: any Database
    ) async throws -> [RenumberedSectionItem] {
        guard Set(items).count == items.count else { throw ReorderError.duplicateItem }
        guard !items.isEmpty else { return [] }
        return try await db.transaction { tx in
            let (assignments, contentItems) = try await rows(for: items, inCourse: courseID, on: tx)
            guard assignments.count + contentItems.count == items.count else {
                throw ReorderError.unknownItem
            }
            let sections = Set(assignments.map(\.sectionID)).union(contentItems.map(\.sectionID))
            guard sections.count == 1 else { throw ReorderError.mixedSections }

            let assignmentByPublicID = Dictionary(uniqueKeysWithValues: assignments.map { ($0.publicID, $0) })
            let contentByID = Dictionary(
                uniqueKeysWithValues: contentItems.compactMap { item in item.id.map { ($0, item) } })
            var renumbered: [RenumberedSectionItem] = []
            for (index, item) in items.enumerated() {
                switch item {
                case .assignment(let publicID):
                    guard let assignment = assignmentByPublicID[publicID] else { throw ReorderError.unknownItem }
                    assignment.sortOrder = index + 1
                    try await assignment.save(on: tx)
                    renumbered.append(.assignment(assignment))
                case .content(let id):
                    guard let contentItem = contentByID[id] else { throw ReorderError.unknownItem }
                    contentItem.sortOrder = index + 1
                    try await contentItem.save(on: tx)
                    renumbered.append(.content(contentItem))
                }
            }
            return renumbered
        }
    }

    /// Writes `sort_order` 1..n onto the course's sections, in the order of
    /// `sectionIDs`, in one transaction. `sectionIDs` must name every section
    /// of the course. The caller has authorized `courseID` at `roleFloor`.
    static func renumberSections(
        _ sectionIDs: [UUID], inCourse courseID: UUID, on db: any Database
    ) async throws -> [APICourseSection] {
        guard Set(sectionIDs).count == sectionIDs.count else { throw ReorderError.duplicateItem }
        return try await db.transaction { tx in
            let sections = try await APICourseSection.query(on: tx).filter(\.$courseID == courseID).all()
            let byID = Dictionary(
                uniqueKeysWithValues: sections.compactMap { section in section.id.map { ($0, section) } })
            guard sectionIDs.allSatisfy({ byID[$0] != nil }) else { throw ReorderError.unknownItem }
            guard sectionIDs.count == sections.count else {
                throw ReorderError.incompleteList(expected: sections.count)
            }
            var renumbered: [APICourseSection] = []
            for (index, id) in sectionIDs.enumerated() {
                guard let section = byID[id] else { throw ReorderError.unknownItem }
                section.sortOrder = index + 1
                try await section.save(on: tx)
                renumbered.append(section)
            }
            return renumbered
        }
    }

    /// The assignment and content-item rows that `items` name, scoped to
    /// `courseID` when it is set.
    private static func rows(
        for items: [SortOrderItem], inCourse courseID: UUID?, on db: any Database
    ) async throws -> ([APIAssignment], [APICourseContentItem]) {
        let publicIDs = items.compactMap(\.assignmentPublicID)
        let contentIDs = items.compactMap(\.contentItemID)
        var assignments: [APIAssignment] = []
        if !publicIDs.isEmpty {
            let query = APIAssignment.query(on: db).filter(\.$publicID ~~ publicIDs)
            if let courseID { query.filter(\.$courseID == courseID) }
            assignments = try await query.all()
        }
        var contentItems: [APICourseContentItem] = []
        if !contentIDs.isEmpty {
            let query = APICourseContentItem.query(on: db).filter(\.$id ~~ contentIDs)
            if let courseID { query.filter(\.$courseID == courseID) }
            contentItems = try await query.all()
        }
        return (assignments, contentItems)
    }
}
