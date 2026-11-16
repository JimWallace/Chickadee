// Tests/APITests/Assignments/AuthoringValidationErrorMessageTests.swift
//
// `AuthoringValidationError.description` is the sentence a page or an MCP
// agent reads when a save is refused. The type's own comment makes it a
// contract: each case reads word for word as the `Abort` reason it replaced.
// The validator suites reach most cases; these are the ones the coverage
// report showed no test reaching. Each test pins the full sentence, so a
// change of wording, a dropped identifier or a case that falls through to
// another case's text fails here.

import Core
import Testing

@testable import APIServer

@Suite struct AuthoringValidationErrorMessageTests {

    struct Case: Sendable, CustomTestStringConvertible {
        let error: AuthoringValidationError
        let message: String
        var testDescription: String { message }
    }

    static let patternKindCases: [Case] = [
        Case(
            error: .differentialReferenceMissing(familyID: "sq"),
            message:
                "Pattern family 'sq' (differential) has no reference implementation. This kind computes each "
                + "case's expected value by running your reference, so there is nothing to compare against "
                + "without one."),
        Case(
            error: .differentialReferenceMissingDefinition(
                familyID: "sq", referenceName: "reference_square", functionName: "square"),
            message:
                "Pattern family 'sq' (differential) must define `reference_square`, which is the name the "
                + "generated test calls. Rename your reference implementation to `reference_square` — it "
                + "takes the same arguments as `square`."),
        Case(
            error: .returnTypeCheckExpectedNotTypeName(familyID: "f", caseKey: "c1"),
            message:
                "Pattern family 'f' (return_type_check): case 'c1' expected must be a non-empty string "
                + "naming the type (e.g. \"int\", \"DataFrame\")"),
        Case(
            error: .exceptionExpectedNotClassName(familyID: "f", caseKey: "c2"),
            message:
                "Pattern family 'f' (exception_expected): case 'c2' expected must be a non-empty string "
                + "naming the exception class (e.g. \"ValueError\")"),
        Case(
            error: .performanceThresholdNotPositive(familyID: "f", caseKey: "c3"),
            message:
                "Pattern family 'f' (performance_threshold): case 'c3' expected must be a positive number "
                + "(milliseconds)"),
    ]

    static let notebookCheckCases: [Case] = [
        Case(
            error: .invalidNotebookCheckTolerance(checkID: "k", kindLabel: "numeric_array_close", tolerance: "rtol"),
            message: "Notebook check 'k' (numeric_array_close): rtol must be a non-negative finite number"),
        Case(
            error: .notebookCheckExpectedCSVMissingHeader(checkID: "k", kindLabel: "data_frame_equality"),
            message: "Notebook check 'k' (data_frame_equality): expectedCSV must begin with a header row"),
        Case(
            error: .dataFrameColumnsEmptyEntry(checkID: "k"),
            message: "Notebook check 'k' (data_frame_columns): expectedColumns contains an empty entry"),
        Case(
            error: .dataFrameColumnsDuplicateNames(checkID: "k"),
            message:
                "Notebook check 'k' (data_frame_columns): expectedColumns contains duplicate names under "
                + "exact matching"),
        Case(
            error: .seriesEqualityCSVHasSeveralColumns(checkID: "k"),
            message:
                "Notebook check 'k' (series_equality): expectedCSV must have exactly one column (header "
                + "had a comma)"),
        Case(
            error: .functionExistsNegativeArity(checkID: "k"),
            message: "Notebook check 'k' (function_exists): expectedArity must be non-negative"),
        Case(
            error: .astStructureInvalidImport(checkID: "k", predicate: "import:1bad"),
            message: "Notebook check 'k' (ast_structure): import predicate 'import:1bad' has an invalid module name"),
        Case(
            error: .astStructureUnknownPredicate(checkID: "k", predicate: "goto"),
            message:
                "Notebook check 'k' (ast_structure): unknown predicate 'goto' — supported: for_loop, "
                + "while_loop, list_comprehension, lambda, recursion, import:<module>, optional leading `!` "
                + "for negation"),
    ]

    static let graphAndFamilyCases: [Case] = [
        Case(
            error: .familyDependsOnUnknownFamily(familyID: "a", dependency: "ghost"),
            message: "Pattern family 'a' depends on unknown family 'ghost'."),
        Case(
            error: .notebookCheckDependsOnUnknownFamily(checkID: "k", familyID: "ghost"),
            message: "Notebook check 'k' depends on unknown pattern family 'ghost'."),
        Case(
            error: .patternCaseKeyInvalid(familyID: "f", caseKey: "bad-key"),
            message: "Pattern family 'f': case key 'bad-key' must contain only letters, digits, and underscore"),
        Case(
            error: .patternCaseMissingLabel(familyID: "f", caseKey: "c1"),
            message: "Pattern family 'f': case 'c1' is missing a label"),
        Case(
            error: .duplicatePatternVariableName(familyID: "f", name: "n"),
            message: "Pattern family 'f': duplicate variable name 'n'"),
        Case(
            error: .patternFamilyIDInvalid(familyID: "bad id"),
            message: "Pattern family id 'bad id' must contain only letters, digits, and underscore"),
        Case(
            error: .duplicatePatternParameterName(familyID: "f", name: "x"),
            message: "Pattern family 'f': duplicate parameter name 'x'"),
    ]

    @Test(arguments: patternKindCases)
    func aPatternKindRuleReadsAsItsSentence(_ entry: Case) {
        #expect(entry.error.description == entry.message)
    }

    @Test(arguments: notebookCheckCases)
    func aNotebookCheckRuleReadsAsItsSentence(_ entry: Case) {
        #expect(entry.error.description == entry.message)
    }

    @Test(arguments: graphAndFamilyCases)
    func aGraphOrFamilyRuleReadsAsItsSentence(_ entry: Case) {
        #expect(entry.error.description == entry.message)
    }

    /// The two differential messages differ only in the arguments they name.
    /// A swap of the two cases' bodies would still pass a "contains the
    /// family id" check, so pin that each names exactly its own extra facts.
    @Test func theTwoDifferentialMessagesNameDifferentFacts() {
        let missing = AuthoringValidationError.differentialReferenceMissing(familyID: "sq").description
        let misnamed = AuthoringValidationError.differentialReferenceMissingDefinition(
            familyID: "sq", referenceName: "ref_sq", functionName: "square"
        ).description
        #expect(!missing.contains("ref_sq"))
        #expect(misnamed.contains("`ref_sq`"))
        #expect(misnamed.contains("`square`"))
        #expect(missing != misnamed)
    }

    /// Every case in these tables is a distinct rule, so no two may read the
    /// same. A copy-paste of one message into another case fails here.
    @Test func noTwoRulesShareASentence() {
        let all = Self.patternKindCases + Self.notebookCheckCases + Self.graphAndFamilyCases
        let messages = all.map(\.error.description)
        #expect(Set(messages).count == messages.count)
    }
}
