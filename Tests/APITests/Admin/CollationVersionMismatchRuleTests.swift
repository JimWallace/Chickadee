// Tests/APITests/Admin/CollationVersionMismatchRuleTests.swift
//
// The `collationVersionMismatch` rule compares the collation version the
// database recorded with the one the running C library or ICU reports. The
// first suite tests the decision: it fires only when both are known and
// differ. The second reads the live test database, which must not fire.

import Testing

@testable import APIServer

@Suite struct CollationVersionMismatchRuleTests {

    @Test func matchingVersionsDoNotFire() {
        #expect(!decideCollationVersionMismatch(recorded: "2.36", actual: "2.36").isFiring)
    }

    /// The builtin provider and the C locale have no version: nothing to compare.
    @Test(arguments: [(String?.none, String?.none), ("2.36", nil), (nil, "2.41")])
    func aMissingVersionDoesNotFire(recorded: String?, actual: String?) {
        #expect(!decideCollationVersionMismatch(recorded: recorded, actual: actual).isFiring)
    }

    @Test func differentVersionsFireWithBothVersionsAndTheFix() {
        let evaluation = decideCollationVersionMismatch(recorded: "2.36", actual: "2.41")
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.contains("2.36"))
        #expect(evaluation.summary.contains("2.41"))
        #expect(evaluation.summary.contains("REINDEX DATABASE"))
        #expect(evaluation.summary.contains("REFRESH COLLATION VERSION"))
        #expect(evaluation.details == ["recorded_version": "2.36", "actual_version": "2.41"])
    }

    @Test func isAWarning() {
        #expect(HealthRule.collationVersionMismatch.severity == "warning")
    }
}

/// The live read, against the test database: a database created on the
/// server that runs it has matching versions (or none), so it stays green.
@Suite(.serialized, .timeLimit(.minutes(2)))
struct CollationRuleDatabaseTests {
    @Test func theTestDatabaseDoesNotFire() async throws {
        try await withTestApp { app in
            let evaluation = try await evaluateCollationVersionMismatch(on: app)
            #expect(!evaluation.isFiring)
        }
    }
}
