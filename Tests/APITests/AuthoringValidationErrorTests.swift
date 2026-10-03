// Tests/APITests/AuthoringValidationErrorTests.swift
//
// The notebook-check validator throws one typed case per rule (#1929). Each
// case must still read as the sentence the old `Abort` carried, and still
// leave a route or an MCP tool as a 422.

import Core
import Testing
import Vapor

@testable import APIServer

@Suite struct AuthoringValidationErrorTests {

    private func variableCheck(_ id: String, points: Int = 1) -> NotebookCheck {
        NotebookCheck(id: id, kind: .variableExists, points: points, variable: "x")
    }

    private func thrownError(
        _ body: () throws -> Void
    ) throws -> AuthoringValidationError {
        let error = try #require(throws: (any Error).self) { try body() }
        return try #require(error as? AuthoringValidationError)
    }

    // MARK: - The validator throws the case for its rule

    @Test func anInvalidIDIsItsOwnCase() throws {
        let error = try thrownError {
            try validateNotebookChecks([variableCheck("bad-id")], language: .python)
        }
        #expect(error == .invalidNotebookCheckID("bad-id"))
    }

    @Test func aDuplicateIDIsItsOwnCase() throws {
        let error = try thrownError {
            try validateNotebookChecks([variableCheck("a"), variableCheck("a")], language: .python)
        }
        #expect(error == .duplicateNotebookCheckID("a"))
    }

    @Test func negativePointsIsItsOwnCase() throws {
        let error = try thrownError {
            try validateNotebookChecks([variableCheck("a", points: -1)], language: .python)
        }
        #expect(error == .negativeNotebookCheckPoints(checkID: "a"))
    }

    @Test func aCollisionWithAHandWrittenFileNamesTheFile() throws {
        let filename = generatedCheckFilename(checkID: "a", tier: .pub, language: .python)
        let error = try thrownError {
            try validateNotebookChecks(
                [variableCheck("a")], testSuites: [TestSuiteEntry(tier: .pub, script: filename)],
                language: .python)
        }
        #expect(error == .notebookCheckCollidesWithHandWrittenFile(checkID: "a", filename: filename))
    }

    @Test func aKindLuaCannotRenderListsTheKindsItCan() throws {
        let check = NotebookCheck(id: "a", kind: .dataFrameShape, variable: "df", expectedRows: 1, expectedCols: 1)
        let error = try thrownError { try validateNotebookChecks([check], language: .lua) }
        guard case .notebookCheckKindUnsupported(let checkID, let kind, let language, let supported, let ext) = error
        else {
            Issue.record("expected notebookCheckKindUnsupported, got \(error)")
            return
        }
        #expect(checkID == "a")
        #expect(kind == .dataFrameShape)
        #expect(language == "Lua")
        #expect(ext == ".lua")
        #expect(supported == supported.sorted())
        #expect(!supported.contains(NotebookCheckKind.dataFrameShape.rawValue))
    }

    @Test func anUploadOnlyLanguageRefusesEveryKind() throws {
        let error = try thrownError { try validateNotebookChecks([variableCheck("a")], language: .cpp) }
        guard case .notebookCheckKindUnavailable(let checkID, _, let language, _, let ext) = error else {
            Issue.record("expected notebookCheckKindUnavailable, got \(error)")
            return
        }
        #expect(checkID == "a")
        #expect(language == .cpp)
        #expect(ext == ".sh")
    }

    @Test func regexMatchingOnLuaIsItsOwnCase() throws {
        let check = NotebookCheck(id: "a", kind: .cellContains, containsText: "x+", regex: true)
        let error = try thrownError { try validateNotebookChecks([check], language: .lua) }
        guard case .notebookCheckRegexUnsupported(let checkID, let kind, let language, _) = error else {
            Issue.record("expected notebookCheckRegexUnsupported, got \(error)")
            return
        }
        #expect(checkID == "a")
        #expect(kind == .cellContains)
        #expect(language == "Lua")
    }

    // MARK: - The message and the status do not change

    @Test(arguments: [
        (
            AuthoringValidationError.invalidNotebookCheckID("x-y"),
            "Notebook check id 'x-y' must contain only letters, digits, and underscore"
        ),
        (.duplicateNotebookCheckID("a"), "Duplicate notebook check id 'a'"),
        (.negativeNotebookCheckPoints(checkID: "a"), "Notebook check 'a': points must be non-negative"),
        (
            .notebookCheckCollidesWithHandWrittenFile(checkID: "a", filename: "f.py"),
            "Notebook check 'a' would generate 'f.py', but a hand-written file with that name already exists. Rename the file or change the check id."
        ),
        (
            .notebookCheckCollidesWithFamilyFile(checkID: "a", filename: "f.py"),
            "Notebook check 'a' would generate 'f.py', which collides with a pattern family's generated filename. Change the check id."
        ),
        (
            .notebookCheckCollidesWithCheckFile(checkID: "a", filename: "f.py"),
            "Notebook check 'a' would generate 'f.py', which collides with another check's generated file. Change the check id."
        ),
        (
            .notebookCheckKindUnsupported(
                checkID: "a", kind: .figureCount, language: "R", supportedKinds: ["k1", "k2"],
                handWrittenExtension: ".R"),
            "Notebook check 'a' (figure_count) is not supported for R assignments — supported kinds are: k1, k2. Express this check as a hand-written .R test for now."
        ),
        (
            .notebookCheckKindUnavailable(
                checkID: "a", kind: .variableExists, language: .racket, reason: "No notebooks.",
                handWrittenExtension: ".rkt"),
            "Notebook check 'a' (variable_exists) is not available for Racket assignments: No notebooks. Use a pattern family or a hand-written .rkt test instead."
        ),
        (
            .notebookCheckRegexUnsupported(checkID: "a", kind: .cellContains, language: "Lua", reason: "Not PCRE."),
            "Notebook check 'a' (cell_contains) uses regex matching, which is not available for Lua assignments: Not PCRE."
        ),
    ])
    func eachCaseReadsAsTheSentenceTheAbortCarried(error: AuthoringValidationError, sentence: String) {
        #expect(error.description == sentence)
        #expect("\(error)" == sentence)
        #expect(error.localizedDescription == sentence)
    }

    @Test func itLeavesARouteAsA422WithTheSameReason() {
        let error: any AbortError = AuthoringValidationError.duplicateNotebookCheckID("a")
        #expect(error.status == .unprocessableEntity)
        #expect(error.reason == "Duplicate notebook check id 'a'")
    }
}
