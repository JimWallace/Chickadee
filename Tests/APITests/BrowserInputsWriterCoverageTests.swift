// Tests/APITests/BrowserInputsWriterCoverageTests.swift
//
// The browser runner writes the per-student inputs file into the grading
// workspace. Two things have to be right: the FILENAME, which must be the one
// that language's `test_runtime` reads, and the RENDERER, which must be that
// language's wrapper.
//
// The filename is no longer this file's problem — `INPUTS_FILE_NAMES` is
// generated from `LanguageDescriptor.inputsFileName` by
// scripts/generate-js-constants.sh, and CI fails if it goes stale. The renderer
// table cannot be generated the same way: the four writers live in the browser's
// own `*-grading-shared.js` modules and have no Swift counterpart to derive
// from. So it stays hand-written, and this is what keeps it honest.
//
// What it prevents is not hypothetical. `INPUTS_WRITERS` replaced an if/else
// chain whose final `else` wrote Python's file, and that chain shipped a bug for
// exactly this reason: a browser-graded Lua assignment took the Python branch,
// wrote `_ck_inputs.py`, and the Lua runtime read `_ck_inputs.lua` and found
// nothing. Every per-student value silently missing, right marks impossible, no
// error anywhere. The `else` is still Python — unreachable in a consistent
// deployment — and a fifth kernel language absent from the table is precisely
// what would make it reachable again.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct BrowserInputsWriterCoverageTests {

    private static let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // APITests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // repo root

    private static func browserRunnerSource() throws -> String {
        try String(
            contentsOf: repoRoot.appendingPathComponent("Public/browser-runner.js"),
            encoding: .utf8)
    }

    /// The language tokens keyed in a `const NAME = { … }` object literal,
    /// found by walking braces so a nested literal cannot end the slice early.
    private static func objectKeys(_ source: String, named name: String) throws -> Set<String> {
        let declaration = "const \(name) = {"
        let start = try #require(
            source.range(of: declaration),
            "\(name) is not declared in Public/browser-runner.js")
        var depth = 1
        var index = start.upperBound
        var body = ""
        while index < source.endIndex, depth > 0 {
            let character = source[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            body.append(character)
            index = source.index(after: index)
        }
        #expect(depth == 0, "\(name)'s literal is never closed")
        let pattern = try NSRegularExpression(pattern: #"([a-zA-Z_][a-zA-Z0-9_]*)\s*:"#)
        let range = NSRange(body.startIndex..., in: body)
        return Set(
            pattern.matches(in: body, range: range).compactMap { match -> String? in
                guard let key = Range(match.range(at: 1), in: body) else { return nil }
                return String(body[key])
            })
    }

    /// The languages a browser can grade: exactly those with a vendored editor
    /// kernel. The upload-only ones never reach this code path at all.
    private static var kernelLanguages: [AssignmentLanguage] {
        AssignmentLanguage.allCases.filter { $0.descriptor.editorSupport != .uploadOnly }
    }

    @Test func everyKernelLanguageHasItsOwnInputsWriter() throws {
        let writers = try Self.objectKeys(try Self.browserRunnerSource(), named: "INPUTS_WRITERS")
        #expect(!writers.isEmpty, "no writer keys were parsed — has the literal's shape changed?")
        for language in Self.kernelLanguages {
            #expect(
                writers.contains(language.rawValue),
                """
                INPUTS_WRITERS in Public/browser-runner.js has no entry for \(language.rawValue), \
                which has an editor kernel and so can be graded in the browser. Without one it \
                falls through to Python's writer and its per-student inputs land in a file its \
                test_runtime does not read — silently, with no error and wrong marks.
                """)
        }
    }

    @Test func noWriterIsOfferedForALanguageTheBrowserCannotGrade() throws {
        let writers = try Self.objectKeys(try Self.browserRunnerSource(), named: "INPUTS_WRITERS")
        let expected = Set(Self.kernelLanguages.map(\.rawValue))
        #expect(
            writers == expected,
            """
            INPUTS_WRITERS keys \(writers.sorted()) do not match the languages with an editor \
            kernel \(expected.sorted()). An extra entry is dead code that reads as coverage.
            """)
    }

    /// The generated filename table covers every language, upload-only included.
    /// Asserted here rather than left to the generator alone, because the
    /// generator only rewrites a block that already exists — a deleted fence
    /// makes it fail, but a hand-edited value between two intact fences would
    /// survive until someone re-ran it.
    @Test func theGeneratedFilenameTableMatchesEveryDescriptor() throws {
        let source = try Self.browserRunnerSource()
        let names = try Self.objectKeys(source, named: "INPUTS_FILE_NAMES")
        #expect(names == Set(AssignmentLanguage.allCases.map(\.rawValue)))
        for language in AssignmentLanguage.allCases {
            #expect(
                source.contains("\(language.rawValue): '\(language.inputsFileName)'"),
                """
                INPUTS_FILE_NAMES does not map \(language.rawValue) to \
                \(language.inputsFileName). Run scripts/generate-js-constants.sh.
                """)
        }
    }
}
