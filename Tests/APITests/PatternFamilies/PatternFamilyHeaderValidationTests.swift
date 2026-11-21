// Tests/APITests/PatternFamilies/PatternFamilyHeaderValidationTests.swift
//
// `validatePatternFamilies` checks the header of each family and each case
// before it looks at the kind. The coverage report showed five of those
// refusals with no test: a family id that is not a filename fragment, a case
// key that is not one, a case label that is only spaces, two family variables
// with one name, and two parameters with one name. Each test below gives one
// such family and expects the exact error. The base family, and the two
// duplicate cases with the names made different, are accepted.

import Core
import Testing

@testable import APIServer

@Suite struct PatternFamilyHeaderValidationTests {

    private func family(
        id: String = "fam", paramNames: [String] = ["x"], caseKey: String = "01",
        label: String = "case", variables: [FamilyVariable] = []
    ) -> PatternFamily {
        PatternFamily(
            id: id, name: "Family", kind: .boundaryEquality, functionName: "f",
            paramNames: paramNames,
            cases: [
                PatternCase(
                    key: caseKey, label: label,
                    args: paramNames.map { _ in JSONValue.int(1) }, expected: .int(1))
            ],
            variables: variables)
    }

    private func validate(_ fam: PatternFamily) throws {
        try validatePatternFamilies([fam], testSuites: [], language: .python)
    }

    @Test func theBaseFamilyIsAccepted() throws {
        try validate(family())
    }

    @Test func aFamilyIDThatIsNotAFilenameFragmentIsRefused() {
        #expect(throws: AuthoringValidationError.patternFamilyIDInvalid(familyID: "bad id")) {
            try validate(family(id: "bad id"))
        }
    }

    @Test func aCaseKeyThatIsNotAFilenameFragmentIsRefused() {
        #expect(
            throws: AuthoringValidationError.patternCaseKeyInvalid(familyID: "fam", caseKey: "a/b")
        ) {
            try validate(family(caseKey: "a/b"))
        }
    }

    @Test func aCaseLabelOfOnlySpacesIsRefused() {
        #expect(
            throws: AuthoringValidationError.patternCaseMissingLabel(familyID: "fam", caseKey: "01")
        ) {
            try validate(family(label: "   "))
        }
    }

    @Test func twoFamilyVariablesWithOneNameAreRefused() throws {
        #expect(
            throws: AuthoringValidationError.duplicatePatternVariableName(familyID: "fam", name: "rows")
        ) {
            try validate(
                family(variables: [
                    FamilyVariable(name: "rows", value: .int(1)),
                    FamilyVariable(name: "rows", value: .int(2)),
                ]))
        }
        try validate(
            family(variables: [
                FamilyVariable(name: "rows", value: .int(1)),
                FamilyVariable(name: "cols", value: .int(2)),
            ]))
    }

    @Test func twoParametersWithOneNameAreRefused() throws {
        #expect(
            throws: AuthoringValidationError.duplicatePatternParameterName(familyID: "fam", name: "x")
        ) {
            try validate(family(paramNames: ["x", "x"]))
        }
        try validate(family(paramNames: ["x", "y"]))
    }
}
