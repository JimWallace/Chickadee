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

    // `variesPerStudent` answers a third question — "can two seeds receive
    // different material?" — and is what multi-variant validation gates on.
    // Deliberately separate from `hasPersonalization`, whose answer also
    // steers the worker download path.

    @Test func aDatasetVariesPerStudentWithoutBeingPersonalization() {
        let manifest = TestProperties(datasets: [DatasetSpec(file: "cases.csv", sampleSize: 5)])
        #expect(manifest.variesPerStudent)
        #expect(
            !manifest.hasPersonalization,
            "a dataset substitutes nothing — the download path must not change")
    }

    @Test func expressionsVaryPerStudentButLiteralsDoNot() {
        #expect(TestProperties(globalExpressions: [expr]).variesPerStudent)
        #expect(
            TestProperties(
                sections: [TestSuiteSection(id: "s1", name: "S1", expressions: [expr])]
            ).variesPerStudent)
        #expect(
            !TestProperties(globalVariables: [literal]).variesPerStudent,
            "every student gets the same literal, so one validation run covers them all")
        #expect(!TestProperties().variesPerStudent)
    }
}
