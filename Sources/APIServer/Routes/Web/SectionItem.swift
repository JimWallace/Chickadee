// APIServer/Routes/Web/SectionItem.swift
//
// One element of a section's item list, on the student dashboard
// (`SectionItem<TestSetupRow>`) and the instructor dashboard
// (`SectionItem<AssignmentRow>`). The two were one struct written twice,
// different only in the name of the assignment key (#1712).

/// A graded assignment row (`row`) OR an ungraded content item (`content`),
/// discriminated by `isContent`. Materials and assignments interleave in one
/// `sort_order` sequence, so a reading can sit between two labs rather than
/// living in a separate lane above them.
struct SectionItem<Row: Encodable>: Encodable {
    let isContent: Bool
    /// Populated when `!isContent`.
    let row: Row?
    /// Populated when `isContent`.
    let content: ContentItemRow?

    static func assignment(_ row: Row) -> SectionItem {
        SectionItem(isContent: false, row: row, content: nil)
    }
    static func material(_ content: ContentItemRow) -> SectionItem {
        SectionItem(isContent: true, row: nil, content: content)
    }
}

/// An element of a section on the student dashboard.
typealias IndexSectionItem = SectionItem<TestSetupRow>

/// An element of a section on the instructor dashboard.
typealias InstructorSectionItem = SectionItem<AssignmentRow>
