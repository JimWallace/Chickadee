// Tests/APITests/PatternFamilies/NotebookCheckKindValidationEdgeTests.swift
//
// Save-time refusals of the notebook-check kind handlers that no other suite
// reaches: tolerances that are negative or not finite, empty or duplicate
// column names, an expected CSV with no header line, a multi-column Series,
// a malformed function name, a negative arity, a blank expected type, and
// AST predicates that are not known. Each refusal must name the exact error,
// because the authoring UI and MCP show its message to the instructor.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookCheckKindValidationEdgeTests {

    private static func validate(_ check: NotebookCheck, language: AssignmentLanguage = .python) throws {
        try notebookCheckKindHandler(for: check.kind).validate(check, language: language)
    }

    // MARK: - Tolerances

    @Test(arguments: [-0.1, Double.nan, Double.infinity])
    func aBadRelativeToleranceIsRefused(rtol: Double) {
        let check = NotebookCheck(
            id: "arr", kind: .numericArrayClose, variable: "values", rtol: rtol, expectedArray: [1, 2])
        #expect(
            throws: AuthoringValidationError.invalidNotebookCheckTolerance(
                checkID: "arr", kindLabel: "numeric_array_close", tolerance: "rtol")
        ) { try Self.validate(check) }
    }

    @Test func aBadAbsoluteToleranceIsRefusedByEachFloatKind() {
        let frame = NotebookCheck(
            id: "df", kind: .dataFrameEquality, variable: "df", expectedCSV: "a\n1\n", atol: -1)
        #expect(
            throws: AuthoringValidationError.invalidNotebookCheckTolerance(
                checkID: "df", kindLabel: "data_frame_equality", tolerance: "atol")
        ) { try Self.validate(frame) }

        let series = NotebookCheck(
            id: "s", kind: .seriesEquality, variable: "s", expectedCSV: "a\n1\n", atol: .infinity)
        #expect(
            throws: AuthoringValidationError.invalidNotebookCheckTolerance(
                checkID: "s", kindLabel: "series_equality", tolerance: "atol")
        ) { try Self.validate(series) }
    }

    @Test func zeroTolerancesAreAccepted() throws {
        let check = NotebookCheck(
            id: "arr", kind: .numericArrayClose, variable: "values", rtol: 0, atol: 0, expectedArray: [1])
        try Self.validate(check)
    }

    // MARK: - Data frame columns

    @Test func anEmptyColumnNameIsRefused() {
        let check = NotebookCheck(
            id: "cols", kind: .dataFrameColumns, variable: "df", expectedColumns: ["age", ""])
        #expect(throws: AuthoringValidationError.dataFrameColumnsEmptyEntry(checkID: "cols")) {
            try Self.validate(check)
        }
    }

    @Test func duplicateColumnsAreRefusedOnlyForAnExactMatch() throws {
        let exact = NotebookCheck(
            id: "cols", kind: .dataFrameColumns, variable: "df", expectedColumns: ["age", "age"])
        #expect(throws: AuthoringValidationError.dataFrameColumnsDuplicateNames(checkID: "cols")) {
            try Self.validate(exact)
        }

        let superset = NotebookCheck(
            id: "cols", kind: .dataFrameColumns, variable: "df", expectedColumns: ["age", "age"],
            columnMatch: .superset)
        try Self.validate(superset)
    }

    // MARK: - Expected CSV

    @Test(arguments: [NotebookCheckKind.dataFrameEquality, .seriesEquality])
    func aCSVWithOnlyLineFeedsHasNoHeader(kind: NotebookCheckKind) {
        let check = NotebookCheck(id: "c", kind: kind, variable: "v", expectedCSV: "\n\n")
        #expect(
            throws: AuthoringValidationError.notebookCheckExpectedCSVMissingHeader(
                checkID: "c", kindLabel: kind.rawValue)
        ) { try Self.validate(check) }
    }

    @Test func aSeriesCSVWithTwoColumnsIsRefused() throws {
        let check = NotebookCheck(id: "s", kind: .seriesEquality, variable: "s", expectedCSV: "a,b\n1,2\n")
        #expect(throws: AuthoringValidationError.seriesEqualityCSVHasSeveralColumns(checkID: "s")) {
            try Self.validate(check)
        }

        let single = NotebookCheck(id: "s", kind: .seriesEquality, variable: "s", expectedCSV: "a\n1\n2\n")
        try Self.validate(single)
    }

    // MARK: - functionExists and variableExists

    @Test func aFunctionNameThatIsNotAnIdentifierIsRefused() {
        let check = NotebookCheck(id: "fn", kind: .functionExists, variable: "2fast")
        #expect(
            throws: AuthoringValidationError.notebookCheckFieldNotIdentifier(
                checkID: "fn", kindLabel: "function_exists", field: "function name", value: "2fast",
                language: .python)
        ) { try Self.validate(check) }
    }

    @Test func aNegativeArityIsRefused() throws {
        let negative = NotebookCheck(id: "fn", kind: .functionExists, variable: "mean", expectedArity: -1)
        #expect(throws: AuthoringValidationError.functionExistsNegativeArity(checkID: "fn")) {
            try Self.validate(negative)
        }

        let zero = NotebookCheck(id: "fn", kind: .functionExists, variable: "mean", expectedArity: 0)
        try Self.validate(zero)
    }

    @Test func aBlankExpectedTypeIsRefused() {
        let check = NotebookCheck(id: "v", kind: .variableExists, variable: "total", expectedType: " \n\t")
        #expect(throws: AuthoringValidationError.variableExistsBlankType(checkID: "v")) {
            try Self.validate(check)
        }
    }

    // MARK: - astStructure

    @Test(arguments: ["import:", "import:os;rm", "!import:a b"])
    func aMalformedImportPredicateIsRefused(predicate: String) {
        let check = NotebookCheck(id: "ast", kind: .astStructure, requiredConstructs: ["for_loop", predicate])
        #expect(throws: AuthoringValidationError.astStructureInvalidImport(checkID: "ast", predicate: predicate)) {
            try Self.validate(check)
        }
    }

    @Test func anUnknownPredicateIsRefusedWithItsNegation() {
        let check = NotebookCheck(id: "ast", kind: .astStructure, requiredConstructs: ["!goto"])
        #expect(throws: AuthoringValidationError.astStructureUnknownPredicate(checkID: "ast", predicate: "!goto")) {
            try Self.validate(check)
        }
    }

    @Test func knownPredicatesNegationsAndDottedImportsAreAccepted() throws {
        let check = NotebookCheck(
            id: "ast", kind: .astStructure,
            requiredConstructs: ["for_loop", "!while_loop", "lambda", "import:numpy.linalg", "!import:os"])
        try Self.validate(check)
    }
}
