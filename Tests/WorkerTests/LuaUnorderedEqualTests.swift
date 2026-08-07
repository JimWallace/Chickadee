// Tests/WorkerTests/LuaUnorderedEqualTests.swift
//
// Executes `chickadee.unordered_equal` against the real `lua` interpreter, over
// the values where it used to disagree with `chickadee.equal` (audit F3). The
// rewrite defines unordered_equal in terms of equal (greedy pairwise multiset
// match), so the invariant is simply: for any two arrays, unordered_equal is
// true whenever equal is — plus it accepts genuine reorderings. Run rather than
// inspected, because the defect was a wrong mark, not a compile error.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.timeLimit(.minutes(2))) struct LuaUnorderedEqualTests {

    static var luaAvailable: Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lua", "-v"]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    /// Runs `program` with the embedded `test_runtime.lua` on `package.path`,
    /// returning trimmed stdout.
    private func runLua(_ program: String) throws -> String {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-unordered-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try testRuntimeLua.write(
            to: dir.appendingPathComponent("test_runtime.lua"), atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lua", "-e", program]
        process.currentDirectoryURL = dir
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(
            in: .whitespacesAndNewlines)
    }

    /// The eight values from the audit table where the old string-keyed
    /// implementation disagreed with `equal`. Every one must now agree.
    @Test func unorderedEqualNeverDisagreesWithEqual() throws {
        guard Self.luaAvailable else { return }
        // Each pair is `{ actual, expected }` as Lua source; the harness reports
        // any pair whose equal / unordered_equal verdicts differ.
        let pairs = [
            "{1,2}, {1.0,2.0}",
            "{{1,2},{3,4}}, {{1.0,2.0},{3.0,4.0}}",
            #"{{"a, b"}}, {{"a","b"}}"#,
            "{{{1,2}}}, {{{9,9}}}",
            "{9007199254740993}, {9007199254740992}",
            "{chickadee.NULL}, {{}}",
            #"{{1}}, {{"1"}}"#,
            "{-0.0, 5}, {0.0, 5}",
        ]
        let cases = pairs.map { "{ \($0) }" }.joined(separator: ", ")
        let program = """
            local chickadee = require("test_runtime")
            local cases = { \(cases) }
            local disagreements = {}
            for i, c in ipairs(cases) do
                local eq = chickadee.equal(c[1], c[2])
                local un = chickadee.unordered_equal(c[1], c[2])
                if eq ~= un then disagreements[#disagreements + 1] = i end
            end
            io.write(#disagreements == 0 and "OK" or ("DISAGREE:" .. table.concat(disagreements, ",")))
            """
        let result = try runLua(program)
        #expect(
            result == "OK",
            "equal and unordered_equal disagree on case(s) \(result) — the F3 regression is back")
    }

    /// The other half of the contract: a genuine reordering (and correct
    /// multiset semantics) must still be accepted, so the fix did not make
    /// unordered_equal a synonym for equal.
    @Test func unorderedEqualStillAcceptsReorderings() throws {
        guard Self.luaAvailable else { return }
        let program = """
            local chickadee = require("test_runtime")
            local ok = chickadee.unordered_equal({1,2,3}, {3,1,2})
                and chickadee.unordered_equal({{1,2},{3,4}}, {{3,4},{1,2}})
                and chickadee.unordered_equal({1,1,2}, {2,1,1})
                and not chickadee.unordered_equal({1,1,2}, {1,2,2})
                and not chickadee.unordered_equal({1,2,3}, {1,2})
            io.write(ok and "OK" or "WRONG")
            """
        #expect(try runLua(program) == "OK")
    }
}
