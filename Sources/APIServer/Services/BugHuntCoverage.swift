// APIServer/Services/BugHuntCoverage.swift
//
// How much of a bug hunt the class has covered (docs/bug-hunt-code-map.md):
// the share of the `bugHunt` block's items that some student's tests have
// passed. Reads `class_item_coverage`, which both result-ingest paths already
// write for a contribution assignment, so nothing new is stored.
//
// The block names items by script filename; coverage rows carry the runner's
// outcome name. The manifest's suite translates one into the other.

import Core
import Fluent
import Foundation

struct BugHuntCoverage: Equatable, Sendable {
    /// The listed items the class has covered, by script filename.
    let coveredItems: Set<String>
    /// How many items the block lists.
    let total: Int

    var coveredCount: Int { coveredItems.count }

    /// The whole percent covered, rounded down, so 100 means every item.
    var percent: Int {
        guard total > 0 else { return 0 }
        return coveredCount * 100 / total
    }

    /// The covered items among `spec.items`, given the outcome names the
    /// coverage table holds. A listed script that is no longer in the suite is
    /// read by its stem, the name the runner would have given it.
    static func make(spec: BugHuntSpec, suite: [TestSuiteEntry], coveredOutcomeNames: Set<String>) -> BugHuntCoverage {
        let entryByScript = Dictionary(suite.map { ($0.script, $0) }, uniquingKeysWith: { first, _ in first })
        let covered = spec.items.filter { script in
            let outcomeName = runnerOutcomeTestName(displayName: entryByScript[script]?.name, script: script)
            return coveredOutcomeNames.contains(outcomeName)
        }
        return BugHuntCoverage(coveredItems: Set(covered), total: spec.items.count)
    }

    /// The class's coverage of the bug hunt behind `testSetupID`.
    static func read(
        testSetupID: String, spec: BugHuntSpec, manifest: TestProperties, on db: any Database
    ) async throws -> BugHuntCoverage {
        let rows = try await classItemCoverage(testSetupID: testSetupID, on: db)
        return make(spec: spec, suite: manifest.testSuites, coveredOutcomeNames: Set(rows.map(\.item)))
    }
}
