// APIServer/Services/ReorderError.swift
//
// Why `SortOrderRenumbering` refused a reorder (#2713). The web routes and the
// MCP tools map each case to their own error type; the rule lives once.

enum ReorderError: Error, Equatable, Sendable {
    /// The list names one item more than once.
    case duplicateItem
    /// An item names a type that is not a `SectionItemKind`.
    case unknownType(String)
    /// An id is not well formed for its type.
    case invalidID(String)
    /// An id names no item in the course.
    case unknownItem
    /// The items are in more than one course section (or in a section and
    /// ungrouped). One reorder renumbers one section.
    case mixedSections
    /// A course-section reorder did not list every section of the course.
    case incompleteList(expected: Int)
    /// A section-item reorder did not list every item of its section
    /// (assignments and content items together).
    case incompleteSection(expected: Int)

    /// One sentence that says what is wrong, for a 400 body or an MCP error.
    var reason: String {
        switch self {
        case .duplicateItem:
            "The list names an item more than once."
        case .unknownType(let raw):
            "\"\(raw)\" is not an item type. Use "
                + SectionItemKind.allCases.map { "\"\($0.rawValue)\"" }.joined(separator: " or ") + "."
        case .invalidID(let raw):
            "\"\(raw)\" is not a valid id."
        case .unknownItem:
            "The list names an item that is not in this course."
        case .mixedSections:
            "The items are in more than one course section. Reorder one section at a time."
        case .incompleteList(let expected):
            "The list must name every section of the course, all \(expected) of them."
        case .incompleteSection(let expected):
            "The list must name every item of the section, assignments and content items together, "
                + "all \(expected) of them."
        }
    }
}
