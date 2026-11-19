// APIServer/Services/SectionPlacement.swift
//
// Where a new or moved item goes in a course section. The web routes and the
// MCP tools share it (#2490). A move into a section changes neither the
// assignment's type nor its grading mode (docs/assignment-types.md).

import Core
import Fluent
import Foundation

/// Next `sort_order` in the per-section item lane of `(course, section)`.
///
/// Assignments and content items share one interleaved sequence, so the next
/// order is the maximum across BOTH tables in this lane, plus one. Every path
/// that creates or moves an assignment or a content item uses it, so a new
/// item sorts after the items already in its section. Before #2490 the
/// content-item paths read only their own table, so a new content item in a
/// section of assignments got order 1 and sorted near the top.
func nextSectionItemSortOrder(
    courseID: UUID, sectionID: UUID?, db: any Database
) async throws -> Int {
    let assignmentQuery = APIAssignment.query(on: db)
        .filter(\.$courseID == courseID)
        // MAX over the non-null rows only; an explicit filter + sort avoids the
        // driver-dependent NULL ordering Postgres and SQLite disagree on.
        .filter(\.$sortOrder != nil)
    let contentQuery = APICourseContentItem.query(on: db)
        .filter(\.$courseID == courseID)
    if let sectionID {
        assignmentQuery.filter(\.$sectionID == sectionID)
        contentQuery.filter(\.$sectionID == sectionID)
    } else {
        assignmentQuery.filter(\.$sectionID == nil)
        contentQuery.filter(\.$sectionID == nil)
    }
    let maxAssignment =
        try await assignmentQuery.sort(\.$sortOrder, .descending).first()?.sortOrder ?? 0
    let maxContent = try await contentQuery.max(\.$sortOrder) ?? 0
    return Swift.max(maxAssignment, maxContent) + 1
}
