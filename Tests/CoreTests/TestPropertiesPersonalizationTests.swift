// Tests/CoreTests/TestPropertiesPersonalizationTests.swift
//
// The shared personalization predicates: `hasExpressions` answers "does this
// manifest need a per-student seed?", `hasPersonalization` answers "is there
// anything to substitute at all?".  Every caller (notebook first-open, worker
// + browser grading inputs, validation materialization, MCP preview) goes
// through these two — the boundary cases here pin the distinction.

import Foundation
import Testing

@testable import Core

@Suite struct TestPropertiesPersonalizationTests {

    private let expr = PersonalizationExpression(name: "x", expression: "seed % 7")
    private let literal = FamilyVariable(name: "limit", value: .int(5))

    @Test func emptyManifestHasNeither() {
        let manifest = TestProperties()
        #expect(!manifest.hasExpressions)
        #expect(!manifest.hasPersonalization)
    }

    @Test func globalExpressionSetsBoth() {
        let manifest = TestProperties(globalExpressions: [expr])
        #expect(manifest.hasExpressions)
        #expect(manifest.hasPersonalization)
    }

    @Test func sectionExpressionSetsBoth() {
        let manifest = TestProperties(
            sections: [TestSuiteSection(id: "s1", name: "S1", expressions: [expr])])
        #expect(manifest.hasExpressions)
        #expect(manifest.hasPersonalization)
    }

    @Test func globalLiteralIsPersonalizationButNeedsNoSeed() {
        let manifest = TestProperties(globalVariables: [literal])
        #expect(!manifest.hasExpressions, "Literals substitute without a seed")
        #expect(manifest.hasPersonalization, "Literal-only manifests still substitute")
    }

    @Test func sectionLiteralIsPersonalizationButNeedsNoSeed() {
        let manifest = TestProperties(
            sections: [TestSuiteSection(id: "s1", name: "S1", variables: [literal])])
        #expect(!manifest.hasExpressions)
        #expect(manifest.hasPersonalization)
    }
}
