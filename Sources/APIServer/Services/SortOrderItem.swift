// APIServer/Services/SortOrderItem.swift
//
// One entry in a course section's display order (#2713). Assignments and
// content items share one per-section `sort_order` sequence, so a section
// reorder is a list of these. `RenumberedSectionItem` is the row after the
// reorder wrote its new position.

import Foundation

/// The two kinds of item a course section holds.
enum SectionItemKind: String, CaseIterable, Sendable {
    case assignment
    case content
}

enum SortOrderItem: Hashable, Sendable {
    case assignment(publicID: String)
    case content(UUID)

    /// Parses one `{type, id}` pair. An unknown type and a malformed id are
    /// refused, never skipped.
    static func parse(type: String, id: String) throws(ReorderError) -> SortOrderItem {
        guard let kind = SectionItemKind(rawValue: type) else { throw .unknownType(type) }
        switch kind {
        case .assignment: return try parseAssignment(id)
        case .content: return try parseContent(id)
        }
    }

    /// Parses an assignment public ID.
    static func parseAssignment(_ raw: String) throws(ReorderError) -> SortOrderItem {
        let id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isValidAssignmentPublicID(id) else { throw .invalidID(raw) }
        return .assignment(publicID: id)
    }

    /// Parses a content-item id.
    static func parseContent(_ raw: String) throws(ReorderError) -> SortOrderItem {
        guard let uuid = UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw .invalidID(raw)
        }
        return .content(uuid)
    }

    var assignmentPublicID: String? {
        guard case .assignment(let publicID) = self else { return nil }
        return publicID
    }

    var contentItemID: UUID? {
        guard case .content(let id) = self else { return nil }
        return id
    }
}

/// A section item with the position the reorder gave it.
enum RenumberedSectionItem: Sendable {
    case assignment(APIAssignment)
    case content(APICourseContentItem)
}
