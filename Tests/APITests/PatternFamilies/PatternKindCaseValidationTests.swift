// Tests/APITests/PatternFamilies/PatternKindCaseValidationTests.swift
//
// Three pattern kinds check their own fields when a family is saved. The
// coverage report showed no test for these refusals:
//
// - `differential`: the reference implementation is empty, or it does not
//   define the name the generated test calls (`ck_ref_<function>`);
// - `return_type_check`: the expected value is not a type name;
// - `performance_threshold`: the expected budget is not a finite number
//   above zero.
//
// Each refusal has an accepted case next to it, so a test cannot pass only
// because the validator refuses everything.

import Core
import Testing

@testable import APIServer

@Suite struct PatternKindCaseValidationTests {

    private func family(
        kind: PatternKind, expected: JSONValue, reference: String? = nil
    ) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: kind, functionName: "square",
            paramNames: ["x"],
            cases: [PatternCase(key: "c1", label: "case", args: [.int(2)], expected: expected)],
            referenceImplementation: reference)
    }

    private func validate(_ fam: PatternFamily) throws {
        try validatePatternFamilies([fam], testSuites: [], language: .python)
    }

    // MARK: - differential

    @Test func aDifferentialFamilyWithAReferenceThatDefinesTheNameIsAccepted() throws {
        try validate(
            family(
                kind: .differential, expected: .null,
                reference: "def ck_ref_square(x):\n    return x * x\n"))
    }

    @Test(arguments: [nil, "", "  \n  "])
    func aDifferentialFamilyWithNoReferenceIsRefused(reference: String?) {
        #expect(throws: AuthoringValidationError.differentialReferenceMissing(familyID: "fam")) {
            try validate(family(kind: .differential, expected: .null, reference: reference))
        }
    }

    @Test func aReferenceThatDoesNotDefineTheCalledNameIsRefused() {
        #expect(
            throws: AuthoringValidationError.differentialReferenceMissingDefinition(
                familyID: "fam", referenceName: "ck_ref_square", functionName: "square")
        ) {
            try validate(
                family(
                    kind: .differential, expected: .null,
                    reference: "def square(x):\n    return x * x\n"))
        }
    }

    // MARK: - return_type_check

    @Test func aReturnTypeCheckWithATypeNameIsAccepted() throws {
        try validate(family(kind: .returnTypeCheck, expected: .string("int")))
    }

    @Test(arguments: [JSONValue.int(3), .string(""), .string("   ")])
    func aReturnTypeCheckWithoutATypeNameIsRefused(expected: JSONValue) {
        #expect(
            throws: AuthoringValidationError.returnTypeCheckExpectedNotTypeName(
                familyID: "fam", caseKey: "c1")
        ) {
            try validate(family(kind: .returnTypeCheck, expected: expected))
        }
    }

    // MARK: - performance_threshold

    @Test(arguments: [JSONValue.int(50), .double(0.5)])
    func aPositiveBudgetIsAccepted(expected: JSONValue) throws {
        try validate(family(kind: .performanceThreshold, expected: expected))
    }

    @Test(arguments: [JSONValue.int(0), .int(-5), .double(-0.1), .double(.infinity), .string("50")])
    func aBudgetThatIsNotAPositiveNumberIsRefused(expected: JSONValue) {
        #expect(
            throws: AuthoringValidationError.performanceThresholdNotPositive(
                familyID: "fam", caseKey: "c1")
        ) {
            try validate(family(kind: .performanceThreshold, expected: expected))
        }
    }
}
