// Tests/WorkerTests/NotebookExtractionProtectionTests.swift
//
// A notebook is extracted to `<stem>.<source extension>`. For R, Lua, Octave
// and Racket that is also a generated test's extension, so a student notebook
// named after a test would replace the test with the student's own code. The
// extractor skips such a notebook and warns instead (#2269).

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct NotebookExtractionProtectionTests {

    private static let notebook = """
        {
          "nbformat": 4,
          "metadata": {"kernelspec": {"name": "ir"}},
          "cells": [{"cell_type": "code", "source": ["quit(status = 0)"]}]
        }
        """

    private func workspace() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-extract-protect-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func aNotebookNamedAfterAProtectedTestIsNotExtractedOverIt() throws {
        let dir = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        let test = dir.appendingPathComponent("publictest_fam_case1.R")
        try "stopifnot(FALSE)".write(to: test, atomically: true, encoding: .utf8)
        try Self.notebook.write(
            to: dir.appendingPathComponent("publictest_fam_case1.ipynb"), atomically: true, encoding: .utf8)

        let warnings = try extractNotebooksToCode(
            in: dir, forcedLanguage: .r, protected: ["publictest_fam_case1.R"])

        #expect(try String(contentsOf: test, encoding: .utf8) == "stopifnot(FALSE)")
        #expect(
            warnings.contains { $0.contains("publictest_fam_case1.ipynb") && $0.contains("publictest_fam_case1.R") })
    }

    @Test func aNotebookWithAnUnprotectedNameIsStillExtracted() throws {
        let dir = try workspace()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Self.notebook.write(
            to: dir.appendingPathComponent("assignment.ipynb"), atomically: true, encoding: .utf8)

        let warnings = try extractNotebooksToCode(
            in: dir, forcedLanguage: .r, protected: ["publictest_fam_case1.R"])

        let source = try String(contentsOf: dir.appendingPathComponent("assignment.R"), encoding: .utf8)
        #expect(source.contains("quit(status = 0)"))
        #expect(warnings.isEmpty)
    }
}
