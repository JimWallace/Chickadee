// Tests/APITests/Assignments/AuthoredGraphPhaseTests.swift
//
// Direct unit tests for three phases in PatternFamilyAuthoredGraph.swift:
// cycle detection, reconstruction of the authored ordering, and family-ref
// dependency validation. Before these tests, only the database-backed
// PatternFamilyApplyTests reached these functions, through
// applyPatternFamilies. A mutation run over the authoring validators
// (2026-11-14) found four mutants that no pure suite could detect:
//
// - `processed == inDegree.count` flipped to `!=` in detectAuthoredCycles;
// - the two appends that put NEW families and NEW checks at the end of the
//   reconstructed ordering, each removed;
// - `fid == f.id` flipped to `!=` in validateFamilyRefDependencies.
//
// Each test below states the invariant that one of those mutants breaks.

import Core
import Testing

@testable import APIServer

@Suite struct AuthoredGraphPhaseTests {

    private func raw(_ script: String, dependsOn: [String] = []) -> AuthoredRawScript {
        AuthoredRawScript(
            script: script, tier: .pub, points: 1, displayName: nil, dependsOn: dependsOn)
    }

    private func family(_ id: String, dependsOn: [String] = []) -> PatternFamily {
        PatternFamily(
            id: id, name: id, kind: .boundaryEquality, functionName: "f",
            paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "one", args: [.int(1)], expected: .int(1))],
            dependsOn: dependsOn)
    }

    // MARK: - detectAuthoredCycles

    @Test func acyclicChainIsAccepted() throws {
        try detectAuthoredCycles(
            authoredRaw: [raw("a.py", dependsOn: ["b.py"]), raw("b.py")],
            families: [family("fam", dependsOn: ["a.py"])])
    }

    @Test func emptyGraphIsAccepted() throws {
        try detectAuthoredCycles(authoredRaw: [], families: [])
    }

    @Test func twoScriptCycleIsRefused() {
        #expect(throws: AuthoringValidationError.authoredDependencyCycle) {
            try detectAuthoredCycles(
                authoredRaw: [raw("a.py", dependsOn: ["b.py"]), raw("b.py", dependsOn: ["a.py"])],
                families: [])
        }
    }

    @Test func cycleThroughAFamilyIsRefused() {
        #expect(throws: AuthoringValidationError.authoredDependencyCycle) {
            try detectAuthoredCycles(
                authoredRaw: [raw("a.py", dependsOn: [familyDepToken("fam")])],
                families: [family("fam", dependsOn: ["a.py"])])
        }
    }

    // MARK: - reconstructAuthoredOrdering

    @Test func newFamiliesAndChecksAreAppendedAfterTheExistingEntries() {
        let props = TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "a.py")], language: .python)
        let rebuilt = reconstructAuthoredOrdering(
            props: props,
            nextFamilies: [family("new_fam")],
            resolvedChecks: [NotebookCheck(id: "new_chk", kind: .variableExists, variable: "x")],
            normaliseSectionID: { $0 })
        #expect(rebuilt.count == 3)
        #expect(rebuilt.dropFirst().first == .family(id: "new_fam", sectionID: nil))
        #expect(rebuilt.last == .check(id: "new_chk", sectionID: nil))
    }

    @Test func aFamilyAlreadyInTheManifestIsNotAppendedTwice() {
        let props = TestProperties(
            testSuites: [
                TestSuiteEntry(tier: .pub, script: "publictest_fam_01.py", generatedBy: "fam"),
                TestSuiteEntry(tier: .pub, script: "a.py"),
            ],
            language: .python)
        let rebuilt = reconstructAuthoredOrdering(
            props: props, nextFamilies: [family("fam")], resolvedChecks: [],
            normaliseSectionID: { $0 })
        #expect(rebuilt.count == 2)
        #expect(rebuilt.first == .family(id: "fam", sectionID: nil))
    }

    // MARK: - validateFamilyRefDependencies

    @Test func familyThatDependsOnItselfIsRefused() {
        #expect(throws: AuthoringValidationError.familyDependsOnItself(familyID: "fam")) {
            try validateFamilyRefDependencies(
                authoredRawEntries: [],
                families: [family("fam", dependsOn: [familyDepToken("fam")])],
                checks: [])
        }
    }

    @Test func familyThatDependsOnAnotherKnownFamilyIsAccepted() throws {
        try validateFamilyRefDependencies(
            authoredRawEntries: [],
            families: [family("first"), family("second", dependsOn: [familyDepToken("first")])],
            checks: [])
    }
}
