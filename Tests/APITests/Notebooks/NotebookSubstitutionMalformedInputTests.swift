// Tests/APITests/Notebooks/NotebookSubstitutionMalformedInputTests.swift
//
// `NotebookSubstitution.apply` gets the notebook bytes that an instructor
// uploaded. The coverage report showed no test for two kinds of input that
// are not a usual notebook: bytes that are not a JSON object, and a JSON
// object with no `cells` array. The first must be refused with
// `notValidNotebookJSON`. The second must come back with the same bytes,
// because there is no code cell to change.

import Foundation
import Testing

@testable import APIServer

@Suite struct NotebookSubstitutionMalformedInputTests {

    @Test(arguments: ["not json at all", "[1, 2, 3]", "\"a string\"", ""])
    func inputThatIsNotAJSONObjectIsRefused(text: String) {
        let error = #expect(throws: NotebookSubstitutionError.self) {
            _ = try NotebookSubstitution.apply(
                notebookData: Data(text.utf8), substitutions: ["rows": "3"])
        }
        #expect(isNotValidNotebookJSON(error))
    }

    private func isNotValidNotebookJSON(_ error: NotebookSubstitutionError?) -> Bool {
        if case .notValidNotebookJSON = error { return true }
        return false
    }

    @Test(arguments: [
        #"{"metadata": {}, "nbformat": 4}"#,
        #"{"cells": "x = {{rows}}", "nbformat": 4}"#,
    ])
    func anObjectWithNoCellsArrayComesBackUnchanged(text: String) throws {
        let data = Data(text.utf8)
        let result = try NotebookSubstitution.apply(
            notebookData: data, substitutions: ["rows": "3"], strict: true)
        #expect(result == data)
    }
}
