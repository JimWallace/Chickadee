// Tests/APITests/PatternFamilies/PatternFamilyCrossFamilyValidationTests.swift
//
// Direct unit tests for three rules in validatePatternFamilies that a mutation
// run over the authoring validators (2026-11-14) found no pure suite could
// detect:
//
// - a `$name` arg reference resolves when the FAMILY declares the variable,
//   even if no section does (`||` flipped to `&&` survived);
// - two families that claim one generated filename are refused
//   (`other != family.id` flipped to `==` survived);
// - a reference implementation that contains the heredoc delimiter on a line
//   of its own is refused (`offending != nil` flipped to `==` survived).

import Core
import Testing

@testable import APIServer

@Suite struct PatternFamilyCrossFamilyValidationTests {

    private func family(
        _ id: String, caseKey: String = "01", argVarRefs: [String?] = [],
        variables: [FamilyVariable] = []
    ) -> PatternFamily {
        PatternFamily(
            id: id, name: id, kind: .boundaryEquality, functionName: "f",
            paramNames: ["x"],
            cases: [
                PatternCase(
                    key: caseKey, label: "case", args: [.int(1)], expected: .int(1),
                    argVarRefs: argVarRefs)
            ],
            variables: variables)
    }

    // MARK: - `$name` arg references

    @Test func argReferenceToAFamilyVariableResolvesWithoutASection() throws {
        let fam = family(
            "fam", argVarRefs: ["rows"], variables: [FamilyVariable(name: "rows", value: .int(3))])
        try validatePatternFamilies([fam], testSuites: [], language: .python)
    }

    @Test func argReferenceToASectionVariableResolvesWithoutAFamilyVariable() throws {
        let fam = family("fam", argVarRefs: ["rows"])
        let section = TestSuiteSection(
            id: "s1", name: "Section", variables: [FamilyVariable(name: "rows", value: .int(3))])
        try validatePatternFamilies(
            [fam], testSuites: [], language: .python, sections: [section],
            familySectionID: ["fam": "s1"])
    }

    @Test func argReferenceThatNothingDeclaresIsRefused() {
        let fam = family("fam", argVarRefs: ["rows"])
        #expect(
            throws: AuthoringValidationError.patternCaseUnknownVariable(
                familyID: "fam", caseKey: "01", argument: "x", reference: "rows")
        ) {
            try validatePatternFamilies([fam], testSuites: [], language: .python)
        }
    }

    // MARK: - Filename collisions between families

    @Test func twoFamiliesThatClaimOneFilenameAreRefused() throws {
        // The generated stem is "<familyID>_<caseKey>", so family `a_b` case `c`
        // and family `a` case `b_c` both produce `publictest_a_b_c.*`.
        let first = family("a_b", caseKey: "c")
        let second = family("a", caseKey: "b_c")
        let error = #expect(throws: AuthoringValidationError.self) {
            try validatePatternFamilies([first, second], testSuites: [], language: .python)
        }
        let thrown = try #require(error)
        #expect(collidingPair(thrown) == ["a", "a_b"])
    }

    /// The two family ids named by a `patternFamiliesCollide` error, or nil for
    /// any other error.
    private func collidingPair(_ error: AuthoringValidationError) -> [String]? {
        switch error {
        case .patternFamiliesCollide(let familyID, let otherFamilyID, _):
            return [familyID, otherFamilyID]
        default:
            return nil
        }
    }

    @Test func familiesWithDistinctStemsAreAccepted() throws {
        try validatePatternFamilies(
            [family("first"), family("second")], testSuites: [], language: .python)
    }

    // MARK: - Heredoc delimiter in a reference implementation

    private func differential(reference: String) -> PatternFamily {
        PatternFamily(
            id: "fam", name: "Family", kind: .differential, functionName: "classify",
            paramNames: ["x"],
            cases: [PatternCase(key: "01", label: "d", args: [.double(18.49)], expected: .null)],
            referenceImplementation: reference)
    }

    @Test func referenceWithTheDelimiterOnItsOwnLineIsRefused() {
        let reference =
            "int ck_ref_classify(double x) {\n"
            + generatedSourceHeredocDelimiter + "\n  return 1;\n}"
        #expect(
            throws: AuthoringValidationError.patternSourceContainsHeredocDelimiter(
                familyID: "fam", delimiter: generatedSourceHeredocDelimiter)
        ) {
            try validatePatternFamilies(
                [differential(reference: reference)], testSuites: [], language: .cpp)
        }
    }

    @Test func referenceThatOnlyMentionsTheDelimiterInsideALineIsAccepted() throws {
        let reference =
            "// " + generatedSourceHeredocDelimiter
            + "\nint ck_ref_classify(double x) { return 1; }"
        try validatePatternFamilies(
            [differential(reference: reference)], testSuites: [], language: .cpp)
    }
}
