// Tests/APITests/Personalization/PersonalizationSubstitutionSectionTests.swift
//
// Pins two parts of `PersonalizationSubstitution` that no database-free suite
// covered (mutation run, 2026-11-18): a suite section's own variables and
// expressions are in the map, and `gradingInputs` returns the evaluated
// values, or nil when nothing evaluated.
//
// Runs a real `python3` subprocess, like the other evaluator suites.

import Core
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct PersonalizationSubstitutionSectionTests {

    private let seed = String(repeating: "a1b2", count: 16)

    @Test func aSectionVariableIsSubstituted() async {
        let manifest = TestProperties(
            language: .python,
            sections: [
                TestSuiteSection(id: "s1", name: "One", variables: [FamilyVariable(name: "x", value: .int(4))])
            ])

        let resolution = await PersonalizationSubstitution.resolve(
            manifest: manifest, seedHex: nil, supportFilesDirectory: nil, language: .python)

        #expect(resolution.substitutions["x"] == "4")
        #expect(resolution.staticNames == ["x"])
    }

    @Test func aSectionExpressionIsEvaluated() async {
        let manifest = TestProperties(
            language: .python,
            sections: [
                TestSuiteSection(
                    id: "s1", name: "One",
                    expressions: [PersonalizationExpression(name: "y", expression: "6 * 7")])
            ])

        let resolution = await PersonalizationSubstitution.resolve(
            manifest: manifest, seedHex: seed, supportFilesDirectory: nil, language: .python)

        #expect(resolution.evaluationError == nil)
        #expect(resolution.evaluatedExpressionNames == ["y"])
        #expect(resolution.substitutions["y"] == "42")
    }

    @Test func gradingInputsCarryTheEvaluatedValues() async {
        let manifest = TestProperties(
            language: .python,
            globalVariables: [FamilyVariable(name: "x", value: .int(4))],
            globalExpressions: [PersonalizationExpression(name: "z", expression: "6 * 7")])

        let inputs = await PersonalizationSubstitution.gradingInputs(
            manifest: manifest, seedHex: seed, courseSeedHex: nil, dealNumber: nil,
            supportFilesDirectory: nil, language: .python)

        #expect(inputs == ["z": "42"])
    }

    @Test func gradingInputsAreNilWhenNothingEvaluated() async {
        let manifest = TestProperties(
            language: .python,
            globalExpressions: [PersonalizationExpression(name: "z", expression: "1 / 0")])

        let inputs = await PersonalizationSubstitution.gradingInputs(
            manifest: manifest, seedHex: seed, courseSeedHex: nil, dealNumber: nil,
            supportFilesDirectory: nil, language: .python)

        #expect(inputs == nil)
    }
}
