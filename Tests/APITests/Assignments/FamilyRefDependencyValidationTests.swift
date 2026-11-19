// Tests/APITests/Assignments/FamilyRefDependencyValidationTests.swift
//
// `validateFamilyRefDependencies` refuses a `family:<id>` dependency that
// names no family. `AuthoredGraphPhaseTests` covers a script that does so and
// a family that names itself. The coverage report showed no test for a
// family, or a notebook check, that names an unknown family. It also showed
// no test for a cycle check where a dependency names a script that is not in
// the authored graph: that script must count as a node with no
// prerequisites, not as a cycle.

import Core
import Testing

@testable import APIServer

@Suite struct FamilyRefDependencyValidationTests {

    private func family(_ id: String, dependsOn: [String] = []) -> PatternFamily {
        PatternFamily(
            id: id, name: id, kind: .boundaryEquality, functionName: "f",
            paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "one", args: [.int(1)], expected: .int(1))],
            dependsOn: dependsOn)
    }

    private func check(_ id: String, dependsOn: [String]) -> NotebookCheck {
        NotebookCheck(id: id, kind: .variableExists, dependsOn: dependsOn, variable: "x")
    }

    @Test func dependenciesOnKnownFamiliesAreAccepted() throws {
        try validateFamilyRefDependencies(
            authoredRawEntries: [],
            families: [family("a", dependsOn: [familyDepToken("b")]), family("b")],
            checks: [check("chk", dependsOn: [familyDepToken("a")])])
    }

    @Test func aFamilyThatDependsOnAnUnknownFamilyIsRefused() {
        #expect(
            throws: AuthoringValidationError.familyDependsOnUnknownFamily(
                familyID: "a", dependency: "ghost")
        ) {
            try validateFamilyRefDependencies(
                authoredRawEntries: [],
                families: [family("a", dependsOn: [familyDepToken("ghost")])],
                checks: [])
        }
    }

    @Test func aNotebookCheckThatDependsOnAnUnknownFamilyIsRefused() {
        #expect(
            throws: AuthoringValidationError.notebookCheckDependsOnUnknownFamily(
                checkID: "chk", familyID: "ghost")
        ) {
            try validateFamilyRefDependencies(
                authoredRawEntries: [],
                families: [family("a")],
                checks: [check("chk", dependsOn: [familyDepToken("ghost")])])
        }
    }

    /// A plain filename dependency is not a family reference, so this check
    /// does not judge it. `validateManifestDependencies` does that later.
    @Test func aPlainFilenameDependencyIsNotJudgedHere() throws {
        try validateFamilyRefDependencies(
            authoredRawEntries: [],
            families: [family("a", dependsOn: ["helper.py"])],
            checks: [check("chk", dependsOn: ["helper.py"])])
    }

    @Test func aDependencyOnAScriptOutsideTheGraphIsNotACycle() throws {
        try detectAuthoredCycles(
            authoredRaw: [
                AuthoredRawScript(
                    script: "a.py", tier: .pub, points: 1, displayName: nil,
                    dependsOn: ["outside.py"])
            ],
            families: [family("fam", dependsOn: ["outside.py", "a.py"])])
    }
}
