// Tests/APITests/SupportImportTests.swift
//
// Slice 5 of issue #461 — personalization expressions can import
// instructor-uploaded `.py` support files and the auto-extracted
// `solution.py` from `solution.ipynb`.  Each test spawns a real
// `python3` subprocess via PersonalizationEvaluator.

import Core
import Foundation
import Testing

@testable import chickadee_server

@Suite final class SupportImportTests {

    private let tempDir: URL

    init() throws {
        self.tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-support-imports-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - SolutionNotebookExtractor

    @Test func extractor_concatenatesCodeCellsSkipsMarkdown() throws {
        let nb: [String: Any] = [
            "cells": [
                ["cell_type": "markdown", "source": "# Welcome"],
                ["cell_type": "code", "source": "def add(a, b):\n    return a + b\n"],
                ["cell_type": "markdown", "source": "more text"],
                ["cell_type": "code", "source": ["def mul(a, b):\n", "    return a * b\n"]],
            ],
            "metadata": [:],
            "nbformat": 4,
            "nbformat_minor": 5,
        ]
        let data = try JSONSerialization.data(withJSONObject: nb)
        let py = try #require(SolutionNotebookExtractor.extractCodeToPython(notebookData: data))
        #expect(py.contains("def add(a, b):"))
        #expect(py.contains("def mul(a, b):"))
        #expect(py.contains("# Welcome") == false)  // markdown skipped
        #expect(py.contains("more text") == false)
    }

    @Test func extractor_writesSolutionPyOnlyWhenAbsent() throws {
        let nb: [String: Any] = [
            "cells": [["cell_type": "code", "source": "def f(x):\n    return x + 1\n"]],
            "metadata": [:],
            "nbformat": 4, "nbformat_minor": 5,
        ]
        let data = try JSONSerialization.data(withJSONObject: nb)
        let shared = tempDir.path + "/"

        // 1. Fresh dir → writes solution.py.
        let didWrite = SolutionNotebookExtractor.writeSolutionPyIfNeeded(
            notebookData: data, sharedDirectory: shared
        )
        #expect(didWrite)
        let pyPath = shared + "solution.py"
        #expect(FileManager.default.fileExists(atPath: pyPath))

        // 2. Instructor's own solution.py wins on re-write.
        let instructorOwn = "INSTRUCTOR_OWN = 42\n"
        try instructorOwn.write(toFile: pyPath, atomically: true, encoding: .utf8)
        let didWriteAgain = SolutionNotebookExtractor.writeSolutionPyIfNeeded(
            notebookData: data, sharedDirectory: shared
        )
        #expect(didWriteAgain == false)
        let onDisk = try String(contentsOfFile: pyPath, encoding: .utf8)
        #expect(onDisk == instructorOwn)
    }

    @Test func extractor_skipsEmptyNotebook() {
        let nb: [String: Any] = [
            "cells": [["cell_type": "markdown", "source": "Just text"]],
            "metadata": [:], "nbformat": 4, "nbformat_minor": 5,
        ]
        let data = try! JSONSerialization.data(withJSONObject: nb)
        let didWrite = SolutionNotebookExtractor.writeSolutionPyIfNeeded(
            notebookData: data, sharedDirectory: tempDir.path + "/"
        )
        #expect(didWrite == false)
        #expect(FileManager.default.fileExists(atPath: tempDir.path + "/solution.py") == false)
    }

    // MARK: - Evaluator with support-file imports

    @Test func evaluator_autoImportsSupportPyModule() async throws {
        // Upload a helpers.py with a function and verify an expression
        // can call it.
        let helpers = "def double(x):\n    return x * 2\n"
        try helpers.write(
            toFile: tempDir.path + "/helpers.py",
            atomically: true, encoding: .utf8)

        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0007",
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "x", expression: "helpers.double(seed)")],
            supportFilesDirectory: tempDir.path
        )
        // seed = 7; double(7) = 14.
        #expect(result["x"] == "14")
    }

    @Test func evaluator_dataFileReadableInExpressionCwd() async throws {
        try "alpha\nbeta\ngamma\n".write(
            toFile: tempDir.path + "/quotes.txt", atomically: true, encoding: .utf8
        )
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0001",
            staticVariables: [],
            expressions: [
                PersonalizationExpression(
                    name: "pick",
                    expression: "open('quotes.txt').read().splitlines()[seed % 3]")
            ],
            supportFilesDirectory: tempDir.path
        )
        // seed = 1; index 1 = "beta".
        #expect(result["pick"] == "'beta'")
    }

    @Test func evaluator_brokenSupportModuleSurfacesWhenReferenced() async throws {
        try "def f(x):\n    return x + 1\n".write(
            toFile: tempDir.path + "/working.py", atomically: true, encoding: .utf8)
        try "this is not valid python\n".write(
            toFile: tempDir.path + "/broken.py", atomically: true, encoding: .utf8)

        // Expression that ignores `broken` succeeds.
        let ok = try await PersonalizationEvaluator.evaluate(
            seedHex: "0003",
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "y", expression: "working.f(seed)")],
            supportFilesDirectory: tempDir.path
        )
        #expect(ok["y"] == "4")

        // Expression that references `broken` errors out cleanly.
        do {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: "0003",
                staticVariables: [],
                expressions: [PersonalizationExpression(name: "z", expression: "broken.f(seed)")],
                supportFilesDirectory: tempDir.path
            )
            Issue.record("Expected nonZeroExit on broken-module reference")
        } catch PersonalizationEvaluatorError.nonZeroExit(_, let stderr) {
            #expect(
                stderr.contains("NameError") || stderr.contains("name 'broken' is not defined"),
                "stderr should mention NameError; got: \(stderr)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func evaluator_staticGlobalShadowsSupportModule() async throws {
        // A static global with the same name as a support module must
        // shadow the auto-imported module (explicit > derived).
        try "VALUE = 999\n".write(
            toFile: tempDir.path + "/helpers.py", atomically: true, encoding: .utf8)

        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0001",
            staticVariables: [
                FamilyVariable(
                    name: "helpers",
                    value: .array([.int(1), .int(2), .int(3)]))
            ],
            expressions: [PersonalizationExpression(name: "first", expression: "helpers[0]")],
            supportFilesDirectory: tempDir.path
        )
        // helpers refers to the static list, not the imported module.
        #expect(result["first"] == "1")
    }

    // MARK: - End-to-end Caesar

    @Test func evaluator_caesarCipherEndToEnd() async throws {
        // Drop a small Caesar-cipher helper.py in the support dir.
        let py = """
            def encode(text, shift):
                out = []
                for c in text:
                    if c.isalpha():
                        base = ord('a') if c.islower() else ord('A')
                        out.append(chr((ord(c) - base + shift) % 26 + base))
                    else:
                        out.append(c)
                return ''.join(out)

            def pick_plaintext(seed, quotes):
                return quotes[seed % len(quotes)]
            """
        try py.write(toFile: tempDir.path + "/cipher.py", atomically: true, encoding: .utf8)

        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "00ff",
            staticVariables: [
                FamilyVariable(
                    name: "quotes",
                    value: .array([.string("hello"), .string("world"), .string("foo")]))
            ],
            expressions: [
                PersonalizationExpression(
                    name: "plaintext",
                    expression: "cipher.pick_plaintext(seed, quotes)"),
                PersonalizationExpression(
                    name: "shift",
                    expression: "seed % 26"),
                PersonalizationExpression(
                    name: "ciphertext",
                    expression: "cipher.encode(plaintext, shift)"),
            ],
            supportFilesDirectory: tempDir.path
        )
        // seed = 0x00ff = 255.  255 % 3 = 0 → plaintext = "hello".
        // 255 % 26 = 21.  encode("hello", 21):
        //   h(7) → (7+21)%26 = 2 → c
        //   e(4) → 25 → z
        //   l(11) → 6 → g
        //   l(11) → 6 → g
        //   o(14) → 9 → j
        //   → "czggj"
        #expect(result["plaintext"] == "'hello'")
        #expect(result["shift"] == "21")
        #expect(result["ciphertext"] == "'czggj'")
    }
}
