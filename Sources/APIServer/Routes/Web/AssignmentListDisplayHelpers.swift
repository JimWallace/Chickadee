// APIServer/Routes/Web/AssignmentListDisplayHelpers.swift
//
// The dashboard display-order rule and the section-grouping fold, shared by
// every page that lists a course's assignments (#1118). Before this, the
// comparator existed ×3 (student dashboard, per-student submissions page,
// grades CSV) and the grouping ×3 (student dashboard, per-student
// submissions page, instructor assignment list) — the same copy-paste class
// that produced the v0.4.82 due-date-timezone bug across five drifted
// display sites.

import Core
import Foundation
import Vapor

// MARK: - Display order

/// The one assignment display-order rule: explicit `sortOrder` first (when
/// both sides carry one and they differ), then the test setup's creation
/// date (newest first), then the setup id for a stable total order.
func assignmentDisplayOrderPrecedes(
    lhsSortOrder: Int?, rhsSortOrder: Int?,
    lhsCreatedAt: Date?, rhsCreatedAt: Date?,
    lhsSetupID: String, rhsSetupID: String
) -> Bool {
    if let l = lhsSortOrder, let r = rhsSortOrder, l != r { return l < r }
    let lhsCreated = lhsCreatedAt ?? .distantPast
    let rhsCreated = rhsCreatedAt ?? .distantPast
    if lhsCreated != rhsCreated { return lhsCreated > rhsCreated }
    return lhsSetupID < rhsSetupID
}

/// `assignmentDisplayOrderPrecedes` over the common "assignments plus their
/// setups by id" shape.
func sortedByAssignmentDisplayOrder(
    _ assignments: [APIAssignment], setupsByID: [String: APITestSetup]
) -> [APIAssignment] {
    assignments.sorted { lhs, rhs in
        assignmentDisplayOrderPrecedes(
            lhsSortOrder: lhs.sortOrder, rhsSortOrder: rhs.sortOrder,
            lhsCreatedAt: setupsByID[lhs.testSetupID]?.createdAt,
            rhsCreatedAt: setupsByID[rhs.testSetupID]?.createdAt,
            lhsSetupID: lhs.testSetupID, rhsSetupID: rhs.testSetupID)
    }
}

// MARK: - Section grouping

/// Buckets display rows into per-section groups (in the sections' given
/// order) plus a trailing ungrouped list. The three grouped pages differed
/// only in whether a section with no visible rows still renders
/// (`includeEmptySections`) and in their row/section context types, so both
/// are parameters. A row whose `sectionIDForRow` names a section not in
/// `sections` is dropped, matching every original site (stale `sectionID`s
/// are normalized away at write time).
func groupRowsBySection<Row, SectionContext>(
    rows: [Row],
    sections: [APICourseSection],
    includeEmptySections: Bool,
    sectionIDForRow: (Row) -> UUID?,
    makeSection: (APICourseSection, [Row]) -> SectionContext
) -> (sections: [SectionContext], ungrouped: [Row]) {
    var rowsBySectionID: [UUID: [Row]] = [:]
    var ungrouped: [Row] = []
    for row in rows {
        if let sectionID = sectionIDForRow(row) {
            rowsBySectionID[sectionID, default: []].append(row)
        } else {
            ungrouped.append(row)
        }
    }
    var contexts: [SectionContext] = []
    for section in sections {
        guard let sectionID = section.id else { continue }
        let sectionRows = rowsBySectionID[sectionID] ?? []
        if sectionRows.isEmpty && !includeEmptySections { continue }
        contexts.append(makeSection(section, sectionRows))
    }
    return (contexts, ungrouped)
}

// MARK: - Per-student submission history rows

/// Builds the rows for a student's per-assignment submission history table —
/// shared by the instructor drilldown (`/instructor/:id/students/:sid/history`)
/// and the course-scoped page (`/:course/students/:token/assignments/:id/history`),
/// whose row builds were byte-identical (#1118). Grades come from the
/// "highest grade wins" map (#1111).
func assignmentSubmissionHistoryRows(
    submissions: [APISubmission],
    bestPercentBySubmissionID: [String: Int],
    fmt: DateFormatter
) -> [AssignmentSubmissionHistoryRow] {
    submissions.map { submission in
        let subID = submission.id ?? ""
        let gradeText: String
        if let pct = bestPercentBySubmissionID[subID] {
            gradeText = "\(pct)%"
        } else {
            gradeText = "—"
        }
        return AssignmentSubmissionHistoryRow(
            submissionID: subID,
            attemptNumber: submission.attemptNumber ?? 1,
            status: submission.status,
            submittedAt: submission.submittedAt.map { fmt.string(from: $0) } ?? "—",
            gradeText: gradeText
        )
    }
}
