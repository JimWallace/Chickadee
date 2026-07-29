// Tests/WorkerTests/RRuntimeJSONEscapingTests.swift
//
// The R runtime hand-formats its result JSON (base R has no jsonlite), so
// `.chickadee_json_str` is the only thing standing between a test message and a
// malformed result line. It had two bugs that hid for months because they only
// bite on particular characters:
//
//   * the backslash escape searched for a DOUBLE backslash, so a single `\` in
//     a message passed through unescaped and the line was invalid JSON. The
//     interpreter then fell back to "last line as plain text" and the student
//     saw the whole `{"status":...}` blob as their result. Regex-based
//     `cell_contains` checks put backslashes in messages routinely.
//   * the quote / newline / CR / tab replacements were each one backslash too
//     many, because `gsub(..., fixed = TRUE)` uses the replacement LITERALLY —
//     no backreference processing. A quote emitted `\\"`, which terminates the
//     JSON string early; a newline emitted `\\n`, which parses but renders to
//     the student as a literal "\n" instead of a line break.
//
// These run the real canonical runtime under Rscript and parse what it prints,
// so the assertions are about observable output rather than the source text.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.serialized, .timeLimit(.minutes(2))) struct RRuntimeJSONEscapingTests {

    /// Runs `passed(<message>)` under the composed runtime and returns the
    /// decoded last stdout line — i.e. exactly what the result interpreter sees.
    /// Launched through `runProcessRobustly` (throttle + bounded exit wait)
    /// with CLOEXEC pipes and a bounded drain — a raw `Process` with
    /// `readDataToEndOfFile()` here pinned a cooperative-pool thread and fed
    /// the #1233 whole-process wedge.
    private func emit(_ rMessageLiteral: String) async throws -> [String: Any]? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-rjson-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try testRuntimeR.write(
            to: dir.appendingPathComponent("test_runtime.R"), atomically: true, encoding: .utf8)
        let script = "source(\"test_runtime.R\")\npassed(\(rMessageLiteral))\n"
        let scriptURL = dir.appendingPathComponent("probe.R")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let proc = try await runProcessRobustly {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = ["Rscript", scriptURL.path]
            proc.currentDirectoryURL = dir
            proc.standardOutput = makeCloexecPipe()
            proc.standardError = makeCloexecPipe()
            return proc
        }
        let out = try #require(proc.standardOutput as? Pipe)
        let data = readToEOFBounded(out)

        guard
            let text = String(data: data, encoding: .utf8),
            let last = text.split(separator: "\n").last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        else { return nil }
        return try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any]
    }

    /// The regression that surfaced it: a regex in the message. Before the fix
    /// this printed invalid JSON and the student saw the raw blob.
    @Test func backslashesSurviveAsValidJSON() async throws {
        guard await rscriptIsAvailable() else { return }
        let decoded = try #require(try await emit(#""Found 1 cell(s) containing `is\\.numeric|summary\\s*\\(`""#))
        #expect(
            decoded["shortResult"] as? String
                == #"Found 1 cell(s) containing `is\.numeric|summary\s*\(`"#)
    }

    /// A quote used to emit `\\"`, which closes the JSON string early.
    @Test func embeddedQuotesDoNotTerminateTheString() async throws {
        guard await rscriptIsAvailable() else { return }
        let decoded = try #require(try await emit(#""expected \"underweight\" here""#))
        #expect(decoded["shortResult"] as? String == #"expected "underweight" here"#)
    }

    /// A newline used to emit `\\n` — valid JSON, but the student saw a literal
    /// backslash-n instead of a line break. Most R failure messages are
    /// multi-line, so this was visible on nearly every failure.
    @Test func newlinesTabsAndCarriageReturnsDecodeToRealControlCharacters() async throws {
        guard await rscriptIsAvailable() else { return }
        let decoded = try #require(try await emit(#""line one\n  indented\ttabbed\r""#))
        let result = try #require(decoded["shortResult"] as? String)
        #expect(result.contains("\n"))
        #expect(result.contains("\t"))
        #expect(result.contains("\r"))
        #expect(!result.contains("\\n"), "a literal backslash-n means the escape is doubled")
        #expect(result == "line one\n  indented\ttabbed\r")
    }

    /// Everything at once, since the passes run in sequence and an ordering
    /// mistake (escaping quotes before backslashes) only shows when combined.
    @Test func allEscapesCompose() async throws {
        guard await rscriptIsAvailable() else { return }
        let decoded = try #require(try await emit(#""a\\b \"q\" \n\t end""#))
        #expect(decoded["shortResult"] as? String == "a\\b \"q\" \n\t end")
        #expect(decoded["status"] as? String == "pass")
    }
}
