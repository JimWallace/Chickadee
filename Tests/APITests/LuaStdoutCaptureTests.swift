// Tests/APITests/LuaStdoutCaptureTests.swift
//
// Executes a generated `.stdoutEquality` Lua test against the real `lua`
// interpreter to prove the capture catches the ways a student actually prints
// (audit F4). The renderer swaps `print` and `io` in the student's environment;
// an earlier version swapped only a bare `io.write`, so `io.stdout:write` and
// chained `io.write(a):write(b)` escaped and a CORRECT submission failed with
// empty output. Verified by running, not reading, because the defect was a
// wrong mark rather than a compile error.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct LuaStdoutCaptureTests {

    static let requiresLua: ConditionTrait = .enabled("requires lua on PATH") { await Self.luaAvailable }

    static var luaAvailable: Bool {
        get async { await toolIsAvailable("lua", arguments: ["-v"]) }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // APITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    /// The generated `.stdoutEquality` case script for Lua (the one that reads
    /// `expected_output`, not any existence guard).
    private func stdoutCaseScript() throws -> String {
        let scripts = renderPatternFamily(
            GeneratedSourceFixtures.family(kind: .stdoutEquality), language: .lua)
        return try #require(scripts.first { $0.source.contains("expected_output") }).source
    }

    /// Grade `submission` with the generated script + the canonical runtime,
    /// returning the outcome status parsed from the last JSON line.
    private func grade(_ submission: String) async throws -> String {
        guard await Self.luaAvailable else { return "pass" }  // skip: treated as no-op
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-luastdout-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = try String(
            contentsOf: Self.repoRoot.appendingPathComponent(
                "Tools/runner-support/test_runtime.lua"), encoding: .utf8)
        try runtime.write(
            to: dir.appendingPathComponent("test_runtime.lua"), atomically: true, encoding: .utf8)
        try stdoutCaseScript().write(
            to: dir.appendingPathComponent("publictest_fam_01.lua"), atomically: true,
            encoding: .utf8)
        try submission.write(
            to: dir.appendingPathComponent("solution.lua"), atomically: true, encoding: .utf8)
        try "solution.lua".write(
            to: dir.appendingPathComponent(".chickadee_student_module"), atomically: true,
            encoding: .utf8)

        let run = try await runTool(["lua", "publictest_fam_01.lua"], workingDirectory: dir)
        let lastLine = run.stdout.split(separator: "\n").last.map(String.init) ?? ""
        if lastLine.contains("\"status\":\"pass\"") { return "pass" }
        if lastLine.contains("\"status\":\"fail\"") { return "fail" }
        return "error"
    }

    // The fixture family prints the string "hello" for `classify`.

    @Test(Self.requiresLua) func printIsCaptured() async throws {
        #expect(try await grade(#"function classify(x) print("hello") end"#) == "pass")
    }

    @Test(Self.requiresLua) func ioStdoutWriteIsCaptured() async throws {
        // The regression: this escaped the old bare-io.write swap and failed a
        // correct submission with empty output.
        #expect(try await grade("function classify(x) io.stdout:write(\"hello\\n\") end") == "pass")
    }

    @Test(Self.requiresLua) func chainedIoWriteIsCaptured() async throws {
        // Chained writes used to crash on the collector returning nil.
        #expect(try await grade("function classify(x) io.write(\"hel\"):write(\"lo\") end") == "pass")
    }

    @Test(Self.requiresLua) func wrongOutputStillFails() async throws {
        // The capture is stronger, but the check still bites.
        #expect(try await grade(#"function classify(x) print("goodbye") end"#) == "fail")
    }
}
