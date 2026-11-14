// Tests/APITests/Notebooks/SolutionNotebookExtractorLanguageTests.swift
//
// `SolutionNotebookExtractor.extractCode` and `writeSolutionSource` for every
// language other than Python. The reference solution a personalization
// expression loads must be the file the RunnerCore extractor builds for a
// student's submission, named `solution.<ext>`, and an instructor-uploaded
// file of that name must win unless the caller asks to overwrite it.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct SolutionNotebookExtractorLanguageTests {

    /// A markdown cell, a code cell with trailing whitespace, and a blank code
    /// cell. Only the second cell is code worth keeping.
    private static let notebook = Data(
        #"""
        {"cells":[
          {"cell_type":"markdown","metadata":{},"source":["# Title\n","Prose only."]},
          {"cell_type":"code","metadata":{},"execution_count":null,"outputs":[],"source":["answer = 42\n","\n"]},
          {"cell_type":"code","metadata":{},"execution_count":null,"outputs":[],"source":"   "}
        ],"metadata":{},"nbformat":4,"nbformat_minor":5}
        """#.utf8)

    private static let markdownOnly = Data(
        #"""
        {"cells":[{"cell_type":"markdown","metadata":{},"source":"# Nothing to run"}],
         "metadata":{},"nbformat":4,"nbformat_minor":5}
        """#.utf8)

    private static func temporaryDirectory() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("solution-extractor-\(UUID().uuidString)", isDirectory: true).path
    }

    @Test(arguments: [
        (AssignmentLanguage.r, "#", "R"),
        (.lua, "--", "lua"),
        (.octave, "%", "m"),
        (.cpp, "//", "cpp"),
        (.racket, ";", "rkt"),
        (.java, "//", "java"),
    ])
    func extractCodeKeepsOnlyCodeCellsBehindAMarker(
        _ language: AssignmentLanguage, _ comment: String, _ ext: String
    ) throws {
        let extracted = try #require(
            SolutionNotebookExtractor.extractCode(notebookData: Self.notebook, language: language))
        #expect(extracted.filename == "solution.\(ext)")
        #expect(
            extracted.source
                == "\(comment) Generated from solution.ipynb\n\n\(comment) ---- chickadee:cell 2 ----\nanswer = 42\n\n")
    }

    @Test func pythonUsesTheResilientPythonExtractor() throws {
        let extracted = try #require(
            SolutionNotebookExtractor.extractCode(notebookData: Self.notebook, language: .python))
        #expect(extracted.filename == "solution.py")
        #expect(extracted.source == SolutionNotebookExtractor.extractCodeToPython(notebookData: Self.notebook))
        #expect(extracted.source.contains("answer = 42"))
        #expect(!extracted.source.contains("Prose only."))
    }

    @Test(arguments: [AssignmentLanguage.r, .lua, .racket])
    func aNotebookWithNoCodeCellsExtractsNothing(_ language: AssignmentLanguage) {
        #expect(SolutionNotebookExtractor.extractCode(notebookData: Self.markdownOnly, language: language) == nil)
    }

    @Test func dataThatIsNotANotebookExtractsNothing() {
        #expect(SolutionNotebookExtractor.extractCode(notebookData: Data("not json".utf8), language: .r) == nil)
    }

    @Test func writeSolutionSourceWritesTheLanguageFile() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let wrote = SolutionNotebookExtractor.writeSolutionSource(
            notebookData: Self.notebook, sharedDirectory: directory, language: .r, overwrite: false)
        #expect(wrote)
        let written = try String(contentsOfFile: directory + "/solution.R", encoding: .utf8)
        #expect(written.contains("answer = 42"))
        #expect(!FileManager.default.fileExists(atPath: directory + "/solution.py"))
    }

    @Test func anExistingFileWinsUnlessOverwriteIsSet() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let target = directory + "/solution.lua"
        try "-- instructor upload\n".write(toFile: target, atomically: true, encoding: .utf8)

        let kept = SolutionNotebookExtractor.writeSolutionSource(
            notebookData: Self.notebook, sharedDirectory: directory, language: .lua, overwrite: false)
        #expect(!kept)
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "-- instructor upload\n")

        let replaced = SolutionNotebookExtractor.writeSolutionSource(
            notebookData: Self.notebook, sharedDirectory: directory, language: .lua, overwrite: true)
        #expect(replaced)
        #expect(try String(contentsOfFile: target, encoding: .utf8).contains("answer = 42"))
    }

    @Test func aNotebookWithNoCodeWritesNoFile() {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let wrote = SolutionNotebookExtractor.writeSolutionSource(
            notebookData: Self.markdownOnly, sharedDirectory: directory, language: .octave, overwrite: true)
        #expect(!wrote)
        #expect(!FileManager.default.fileExists(atPath: directory + "/solution.m"))
    }

    @Test func pythonDelegatesToWriteSolutionPy() throws {
        let directory = Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory) }

        let wrote = SolutionNotebookExtractor.writeSolutionSource(
            notebookData: Self.notebook, sharedDirectory: directory, language: .python, overwrite: false)
        #expect(wrote)
        let written = try String(contentsOfFile: directory + "/solution.py", encoding: .utf8)
        #expect(written == SolutionNotebookExtractor.extractCodeToPython(notebookData: Self.notebook))
    }
}
