// APIServer/Services/SectionPlacement.swift
//
// Where a new or moved item goes in a course section, and what a move into a
// section does to the grading mode. The web routes and the MCP tools share
// both (#2490).

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

/// Gives a setup the default grading mode of the section its assignment moved
/// into, and returns the grading mode the setup has afterwards.
///
/// The mode is kept when adopting the default would break a manifest rule
/// (`ManifestCoherence`), for example browser grading on an upload-only
/// assignment. The move itself still succeeds: a drag into a section is not
/// the place to surface that refusal. The web move and MCP
/// `set_assignment_course_section` both call it. Each used to restate three of
/// the rules, so a new rule would have reached `setManifestGradingMode` after
/// the move had already saved, and failed it.
@discardableResult
func adoptSectionGradingMode(
    _ section: APICourseSection, setup: APITestSetup, on db: any Database
) async throws -> String {
    guard let mode = GradingMode(rawValue: section.defaultGradingMode),
        ManifestCoherence.violation(introducedBy: { $0.gradingMode = mode }, in: setup.manifest) == nil
    else { return currentManifestGradingMode(setup.manifest) }
    return try await setManifestGradingMode(setup: setup, to: mode.rawValue, on: db)
}
