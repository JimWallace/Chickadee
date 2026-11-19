// Tests/APITests/Assignments/SubmissionFilenameFallbackTests.swift
//
// `submissionFilenameForStorage` replaces the name with the fallback in two
// places: when the uploaded name is empty, and when nothing is left after
// the separator and control characters are removed. The coverage report
// showed no test for the second place. `notebookFilenameForStorage` adds
// `.ipynb` when the name does not end with it, in any letter case.

import Testing

@testable import APIServer

@Suite struct SubmissionFilenameFallbackTests {

    @Test(arguments: ["***", "?<>|", "\"\"", "a/:"])
    func aNameOfOnlyRemovedCharactersUsesTheFallback(uploaded: String) {
        #expect(submissionFilenameForStorage(uploadedName: uploaded, fallback: "solution.py") == "solution.py")
    }

    @Test func aMissingNameUsesTheFallback() {
        #expect(submissionFilenameForStorage(uploadedName: nil, fallback: "solution.py") == "solution.py")
    }

    @Test func aNameWithSomeUsableCharactersKeepsThem() {
        #expect(submissionFilenameForStorage(uploadedName: "*lab?.py", fallback: "solution.py") == "lab .py")
    }

    @Test func aNotebookNameGetsTheExtensionOnlyWhenItLacksIt() {
        #expect(notebookFilenameForStorage(uploadedName: "lab1", fallback: "nb") == "lab1.ipynb")
        #expect(notebookFilenameForStorage(uploadedName: "Lab1.IPYNB", fallback: "nb") == "Lab1.IPYNB")
        #expect(notebookFilenameForStorage(uploadedName: "***", fallback: "starter") == "starter.ipynb")
    }
}
