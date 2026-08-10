// Tests/APITests/PatternFamilyExistenceGuardTests.swift
//
// Phase 1: every function-calling pattern family auto-generates one
// existence guard (`{tier}test_{id}_exists.py`, 0 points) that its cases
// `dependsOn`.  A missing/non-callable target fails once on the guard and
// the cases auto-skip through the runner's dependency gate, instead of N
// opaque AttributeError tracebacks.  `.variableEquality` keeps self-guarding
// each case, so it gets no guard.

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct PatternFamilyExistenceGuardTests {

    // MARK: - existenceGuard(for:) shape

    @Test func existenceGuard_isNilForVariableEqualityAndEmptyFamilies() throws {
        // variableEquality self-guards each case; no separate guard.
        #expect(existenceGuard(for: pfNotebookVariablesFamily(), language: .python) == nil)

        // No enabled cases → nothing to gate → nil.
        let allDisabled = PatternFamily(
            id: "d", name: "D", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            cases: [
                PatternCase(
                    key: "01", label: "a", args: [.int(1)], expected: .int(1), enabled: false)
            ]
        )
        #expect(existenceGuard(for: allDisabled, language: .python) == nil)
    }

    @Test func existenceGuard_isZeroPointAndCarriesFamilyDefaultTier() throws {
        let g = try #require(existenceGuard(for: pfBMIFamily(), language: .python))
        #expect(g.points == 0, "the guard gates, it doesn't grade")
        #expect(g.caseKey == patternExistenceGuardCaseKey)
        #expect(g.tier == .pub)
        #expect(g.displayName == "bmi_category is defined")
        #expect(g.filename == "publictest_bmi_category_exists.py")
        // First comment line is the student-facing label (test_runtime label picker).
        #expect(g.source.hasPrefix("# Test: bmi_category is defined\n"))
        #expect(g.source.contains("spec_hash="))
    }

    @Test func existenceGuard_followsFamilyDefaultTierIntoFilename() throws {
        let secretFamily = pfBMIFamily(tier: .secret)
        let g = try #require(existenceGuard(for: secretFamily, language: .python))
        #expect(g.tier == .secret)
        #expect(g.filename == "secrettest_bmi_category_exists.py")
    }

    // MARK: - Generated guard actually grades

    @Test func existenceGuard_sourceIsValidPython() throws {
        let g = try #require(existenceGuard(for: pfBMIFamily(), language: .python))
        try pfAssertValidPythonSyntax(g.source, label: "existence guard")
    }

    @Test func existenceGuard_passesWhenDefinedFailsOtherwise() throws {
        let body = try #require(existenceGuard(for: pfBMIFamily(), language: .python)).source
        // Defined + callable → pass.
        #expect(
            try pfRunGeneratedCase(
                body: body, ckInputs: nil,
                student: "def bmi_category(x):\n    return 'underweight'\n") == .pass)
        // Not defined → fail (the one clear message; cases would skip).
        #expect(
            try pfRunGeneratedCase(
                body: body, ckInputs: nil, student: "answer = 1\n") == .fail)
        // Defined but not callable (shadowed by a value) → fail.
        #expect(
            try pfRunGeneratedCase(
                body: body, ckInputs: nil, student: "bmi_category = 42\n") == .fail)
    }

    // MARK: - Validator reserves the guard case key

    @Test func validator_rejectsReservedCaseKeyForFunctionCallingKind() throws {
        let fam = PatternFamily(
            id: "f", name: "F", kind: .boundaryEquality,
            functionName: "f", paramNames: ["x"],
            cases: [
                PatternCase(
                    key: patternExistenceGuardCaseKey, label: "clash",
                    args: [.int(1)], expected: .int(1))
            ]
        )
        do {
            try validatePatternFamilies([fam], testSuites: [])
            Issue.record("Expected the reserved guard case key to be rejected")
        } catch let abort as AbortError {
            #expect("\(abort.reason)".contains("reserved"))
        }
    }

    @Test func validator_allowsReservedKeyForVariableEquality() throws {
        // variableEquality has no guard, so the key isn't reserved there.
        let fam = PatternFamily(
            id: "v", name: "V", kind: .variableEquality,
            functionName: "_", paramNames: ["variable"],
            cases: [
                PatternCase(
                    key: patternExistenceGuardCaseKey, label: "exists var",
                    args: [.string("answer")], expected: .int(42))
            ]
        )
        try validatePatternFamilies([fam], testSuites: [])
    }

    // MARK: - Apply wiring

    // These apply-path assertions read the call's own return value
    // (`result.manifestAfter` / `.writtenFiles`) rather than re-reading
    // `fixture.setup.manifest`, so they're immune to the shared in-memory
    // SQLite identity-map contamination that can cross-pollinate the setup
    // object under heavy parallel local runs (CI uses per-schema Postgres).

    @Test func apply_variableEqualityFamilyHasNoGuardEntry() async throws {
        try await withPatternFamilyFixture { fixture in
            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfNotebookVariablesFamily()], on: fixture.app.db)
            let props = try pfDecodeManifest(result.manifestAfter)
            let generated = props.testSuites.filter { $0.generatedBy != nil }
            #expect(generated.count == 2, "variableEquality self-guards; no extra guard entry")
            #expect(generated.allSatisfy { !$0.script.hasSuffix("_exists.py") })
        }
    }

    @Test func apply_approximateEqualityFamilyGetsGuard() async throws {
        try await withPatternFamilyFixture { fixture in
            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfApproxFamily()], on: fixture.app.db)
            let guardName = pfGuardFilename("bmi_kg_m2")
            // Guard file written to the zip.
            #expect(result.writtenFiles.contains(guardName))
            let props = try pfDecodeManifest(result.manifestAfter)
            let guardEntry = try #require(props.testSuites.first { $0.script == guardName })
            #expect(guardEntry.generatedBy == "bmi_kg_m2")
            #expect(guardEntry.points == 0)
            // Both cases depend on the guard.
            let cases = props.testSuites.filter { $0.generatedBy == "bmi_kg_m2" && $0.script != guardName }
            #expect(cases.count == 2)
            #expect(cases.allSatisfy { $0.dependsOn.contains(guardName) })
        }
    }

    // MARK: - Author-view round-trip (guard stays invisible)

    /// The guard is a generated entry tagged `generatedBy` the family, so
    /// `buildSuitePayload` collapses it into the single family row — it must
    /// never surface as its own editor row, and the family row's `dependsOn`
    /// stays the authored family-level list (no internal guard edge).
    @Test func buildSuitePayload_collapsesGuardIntoFamilyRow() async throws {
        try await withPatternFamilyFixture { fixture in
            let result = try await applyPatternFamilies(
                to: fixture.setup, nextFamilies: [pfBMIFamily()], on: fixture.app.db)

            let payload = buildSuitePayload(fromManifest: result.manifestAfter)
            #expect(payload.items.count == 1, "guard collapses into the family row — no extra item")
            let family = try #require(payload.items.first)
            #expect(family.kind == "family")
            #expect(family.family?.id == "bmi_category")
            #expect((family.dependsOn ?? []).isEmpty, "family row keeps the authored (empty) deps, not the guard edge")
            // The guard never leaks as a script row.
            #expect(payload.items.allSatisfy { $0.script?.script != pfGuardFilename("bmi_category") })
        }
    }
}
