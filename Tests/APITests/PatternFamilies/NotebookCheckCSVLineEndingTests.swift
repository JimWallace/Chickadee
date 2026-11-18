// Tests/APITests/PatternFamilies/NotebookCheckCSVLineEndingTests.swift
//
// The data-frame and Series equality kinds read the first line of the expected
// CSV as its header. In Swift, "\r\n" is one `Character` that equals neither
// "\n" nor "\r", so a split on those two never split a CSV with Windows line
// endings. The whole text was read as the header: a CSV with no header passed,
// and a one-column Series with a comma in a later row was refused.
// Blank lines before the header are skipped, as they are with LF endings.

import Core
import Testing

@testable import APIServer

@Suite struct NotebookCheckCSVLineEndingTests {

    private static func validate(_ check: NotebookCheck) throws {
        try notebookCheckKindHandler(for: check.kind).validate(check, language: .python)
    }

    @Test(arguments: ["\n\r\n", "\r\n\r\n", "\r\n"])
    func aDataFrameCSVOfOnlyLineBreaksIsRefused(csv: String) {
        let check = NotebookCheck(id: "df", kind: .dataFrameEquality, variable: "df", expectedCSV: csv)
        #expect(
            throws: AuthoringValidationError.notebookCheckExpectedCSVMissingHeader(
                checkID: "df", kindLabel: "data_frame_equality")
        ) { try Self.validate(check) }
    }

    @Test(arguments: ["\n\r\n", "\r\n\r\n"])
    func aSeriesCSVOfOnlyLineBreaksIsRefused(csv: String) {
        let check = NotebookCheck(id: "s", kind: .seriesEquality, variable: "s", expectedCSV: csv)
        #expect(
            throws: AuthoringValidationError.notebookCheckExpectedCSVMissingHeader(
                checkID: "s", kindLabel: "series_equality")
        ) { try Self.validate(check) }
    }

    @Test(arguments: ["value\r\n1\r\n\"2,5\"\r\n", "value\n1\n\"2,5\"\n", "value\r1\r\"2,5\"\r"])
    func aOneColumnSeriesIsAcceptedWhateverItsLineEndings(csv: String) throws {
        let check = NotebookCheck(id: "s", kind: .seriesEquality, variable: "s", expectedCSV: csv)
        try Self.validate(check)
    }

    @Test func aTwoColumnSeriesHeaderIsStillRefusedWithCRLF() {
        let check = NotebookCheck(id: "s", kind: .seriesEquality, variable: "s", expectedCSV: "a,b\r\n1,2\r\n")
        #expect(throws: AuthoringValidationError.seriesEqualityCSVHasSeveralColumns(checkID: "s")) {
            try Self.validate(check)
        }
    }

    @Test func aDataFrameCSVWithCRLFAndAHeaderIsAccepted() throws {
        let check = NotebookCheck(
            id: "df", kind: .dataFrameEquality, variable: "df", expectedCSV: "age,bmi\r\n40,22.5\r\n")
        try Self.validate(check)
    }
}
