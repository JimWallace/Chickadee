// Tests/APITests/LuaProgramIOTests.swift
//
// The Lua `.programIO` rendering executed under the real `lua` and the
// canonical runtime: `io.read` in its number, line and whole-file forms,
// `io.lines()`, and an `os.exit` after the answer — every one of which the
// generated script proxies in the environment the submission runs in.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct LuaProgramIOTests {

    static var luaAvailable: Bool {
        get async { await LuaStdoutCaptureTests.luaAvailable }
    }

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // APITests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
    }

    private func grade(
        _ submission: String, stdin: String = "3\n4\n", expected: String = "7",
        comparison: ProgramIOComparison? = nil
    ) async throws -> String {
        let family = PatternFamily(
            id: "io", name: "IO", kind: .programIO, functionName: "", paramNames: ["stdin"],
            cases: [PatternCase(key: "01", label: "sum", args: [.string(stdin)], expected: .string(expected))],
            ioComparison: comparison)
        let script = try #require(renderPatternFamily(family, language: .lua).first)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-luaio-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runtime = try String(
            contentsOf: Self.repoRoot.appendingPathComponent("Tools/runner-support/test_runtime.lua"),
            encoding: .utf8)
        try runtime.write(to: dir.appendingPathComponent("test_runtime.lua"), atomically: true, encoding: .utf8)
        try script.source.write(to: dir.appendingPathComponent(script.filename), atomically: true, encoding: .utf8)
        try submission.write(to: dir.appendingPathComponent("solution.lua"), atomically: true, encoding: .utf8)
        try "solution.lua".write(
            to: dir.appendingPathComponent(".chickadee_student_module"), atomically: true, encoding: .utf8)

        let run = try await runTool(["lua", script.filename], workingDirectory: dir)
        let lastLine = run.stdout.split(separator: "\n").last.map(String.init) ?? ""
        if lastLine.contains("\"status\":\"pass\"") { return "pass" }
        if lastLine.contains("\"status\":\"fail\"") { return "fail" }
        return "error"
    }

    @Test func numberReadsPassAndFail() async throws {
        guard await Self.luaAvailable else { return }
        #expect(try grade("local a = io.read(\"n\")\nlocal b = io.read(\"n\")\nprint(a + b)\n") == "pass")
        #expect(try grade("local a = io.read(\"*n\")\nlocal b = io.read(\"*n\")\nprint(a * b)\n") == "fail")
    }

    @Test func lineReadsAndIoLinesIterate() async throws {
        guard await Self.luaAvailable else { return }
        #expect(
            try grade("local a = io.read()\nlocal b = io.read(\"l\")\nprint(tonumber(a) + tonumber(b))\n") == "pass")
        #expect(try grade("local t = 0\nfor line in io.lines() do t = t + tonumber(line) end\nprint(t)\n") == "pass")
        #expect(
            try grade("local t = 0\nfor line in io.stdin:lines() do t = t + tonumber(line) end\nio.write(t, \"\\n\")\n")
                == "pass")
    }

    @Test func wholeInputReadAndIncludedComparison() async throws {
        guard await Self.luaAvailable else { return }
        #expect(try grade("io.write(\"got: \", io.read(\"a\"))\n", expected: "got: 3\n4") == "pass")
        #expect(try grade("print(\"answer is 7\")\n", comparison: .included) == "pass")
    }

    @Test func anOsExitAfterTheAnswerIsStillGraded() async throws {
        guard await Self.luaAvailable else { return }
        #expect(try grade("print(io.read(\"n\") + io.read(\"n\"))\nos.exit(0)\n") == "pass")
        #expect(try grade("print(0)\nos.exit(0)\n") == "fail")
    }

    @Test func aCrashIsAGradedFailure() async throws {
        guard await Self.luaAvailable else { return }
        #expect(try grade("error(\"boom\")\n") == "fail")
    }
}
