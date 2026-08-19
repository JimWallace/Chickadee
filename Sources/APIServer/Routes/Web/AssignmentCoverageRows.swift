// APIServer/Routes/Web/AssignmentCoverageRows.swift
//
// Builds the instructor-facing view of a contribution assignment's class-wide
// coverage: every suite item, whether the class has collectively covered it,
// and who got there first.
//
// The uncovered items are the point. A list of what the class HAS found is a
// scoreboard; a list that also shows what is still missing is the thing an
// instructor acts on mid-lab — which bugs still need someone to go after. So
// the rows come from the manifest's suite (every item the assignment defines)
// left-joined onto the coverage table, not from the coverage table alone.

import Core
import Fluent
import Foundation

/// The coverage rows for one assignment, or `[]` when it is not a contribution
/// assignment.
///
/// Emptiness is the gate. `recordClassItemCoverage` only writes rows for an
/// assignment declaring contribution slots, so no rows means no section — an
/// ordinary lab's page is unchanged, with no second signal to consult and no
/// starter-notebook read on a page that batches its queries carefully.
func buildAssignmentCoverageRows(
    testSetupID: String,
    manifest: TestProperties?,
    formatter: DateFormatter,
    on db: Database
) async throws -> [AssignmentCoverageRow] {
    let covered = try await classItemCoverage(testSetupID: testSetupID, on: db)
    guard !covered.isEmpty else { return [] }

    // One query for the finders rather than one per row.
    let finderIDs = Array(Set(covered.map(\.userID)))
    let finders = try await APIUser.query(on: db).filter(\.$id ~~ finderIDs).all()
    var usernameByID: [UUID: String] = [:]
    for user in finders { if let id = user.id { usernameByID[id] = user.username } }

    var coverageByItem: [String: APIClassItemCoverage] = [:]
    for row in covered { coverageByItem[row.item] = row }

    // Every item the suite defines, in suite order, so an uncovered item still
    // has a row. A covered item whose suite entry has since been deleted also
    // keeps its row — dropping it would quietly shrink the denominator an
    // instructor is reading against.
    var items = (manifest?.testSuites ?? []).map {
        runnerOutcomeTestName(displayName: $0.name, script: $0.script)
    }
    for item in covered.map(\.item) where !items.contains(item) { items.append(item) }

    let iso = ISO8601DateFormatter()
    return items.map { item in
        guard let row = coverageByItem[item] else {
            return AssignmentCoverageRow(
                item: item, found: false, foundBy: "", foundAt: "", foundAtISO: "")
        }
        return AssignmentCoverageRow(
            item: item,
            found: true,
            foundBy: usernameByID[row.userID] ?? "unknown",
            foundAt: row.coveredAt.map { formatter.string(from: $0) } ?? "",
            foundAtISO: row.coveredAt.map { iso.string(from: $0) } ?? "")
    }
}

/// "9 / 15 found" — the section's summary chip.
func assignmentCoverageSummary(_ rows: [AssignmentCoverageRow]) -> String {
    "\(rows.filter(\.found).count) / \(rows.count) found"
}
