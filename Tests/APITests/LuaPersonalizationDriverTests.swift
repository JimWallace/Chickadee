// Tests/APITests/LuaPersonalizationDriverTests.swift
//
// The Lua expression driver, executed rather than inspected.
//
// Two things here cannot be checked by reading the code, and both are wrong
// marks rather than crashes when they break:
//
// 1. THE DRIVER'S OUTPUT IS LUA SOURCE, not a display form. The server writes it
//    verbatim into `_ck_inputs.lua`, so a value that renders as something Lua
//    cannot parse makes every per-student input silently read as missing (the
//    reader's `pcall` swallows the load error and answers `{}`).
//
// 2. THE SEED THE DRIVER BINDS MUST EQUAL THE SEED A GRADED SCRIPT READS.
//    `LuaPersonalizationRuntime.chickadeeSeedLuaSource` and `chickadee.seed()`
//    in `test_runtime.lua` are two copies of one Horner fold. If they diverge,
//    an instructor's `preview_personalization` shows one set of values and the
//    student's tests grade against another — with nothing failing anywhere.
//
// Skipped silently when `lua` is absent, matching the conformance matrix: a
// missing interpreter on a contributor's laptop is not a defect. CI has
// lua5.4 on the image.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct LuaPersonalizationDriverTests {

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

    /// Runs `source` as a Lua script in a fresh directory, returning
    /// (exitCode, stdout, stderr). `extraFiles` are written beside it.
    static func runLua(
        _ source: String,
        extraFiles: [String: String] = [:],
        seed: String? = nil
    ) throws -> (Int32, String, String) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-luadriver-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        for (name, contents) in extraFiles {
            try contents.write(
                to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let script = dir.appendingPathComponent("driver.lua")
        try source.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["lua", script.path]
        process.currentDirectoryURL = dir
        if let seed {
            var env = ProcessInfo.processInfo.environment
            env["CHICKADEE_ASSIGNMENT_SEED"] = seed
            process.environment = env
        }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// The canonical grading runtime, so a test can require it the way a
    /// generated script does.
    static func testRuntimeLuaSource() throws -> String {
        try String(
            contentsOf: LanguageConformanceMatrixTests.repoRoot
                .appendingPathComponent("Tools/runner-support/test_runtime.lua"),
            encoding: .utf8)
    }

    @Test func theDriverEvaluatesExpressionsAndEmitsLuaLiterals() throws {
        guard Self.luaAvailable else { return }

        let source = PersonalizationEvaluator.renderLuaDriverScript(
            staticVariables: [FamilyVariable(name: "base", value: .int(10))],
            expressions: [
                PersonalizationExpression(name: "doubled", expression: "base * 2"),
                // References an earlier expression, which is what forces the
                // driver to extend one scope rather than evaluating each in
                // isolation.
                PersonalizationExpression(name: "quadrupled", expression: "doubled * 2"),
                PersonalizationExpression(name: "label", expression: "\"row \" .. doubled"),
                PersonalizationExpression(name: "values", expression: "{1, 2.5, \"three\"}"),
            ]
        )
        let (code, stdout, stderr) = try Self.runLua(source, seed: String(repeating: "a", count: 64))
        #expect(code == 0, "driver failed: \(stderr)")

        let lastLine = stdout.split(separator: "\n").last.map(String.init) ?? ""
        let decoded =
            (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: String]
        let values = try #require(decoded, "driver did not emit a JSON map; stdout was: \(stdout)")

        #expect(values["doubled"] == "20")
        #expect(values["quadrupled"] == "40")
        #expect(values["label"] == "\"row 20\"")
        // Emitted as Lua source, so the float keeps its decimal point and the
        // string keeps its quotes — this is what lands in `_ck_inputs.lua`.
        #expect(values["values"] == "{1, 2.5, \"three\"}")
    }

    /// The emitted literals must be *parseable Lua*, not merely plausible. This
    /// is the property that makes the driver's output safe to write verbatim
    /// into the inputs file.
    @Test func everyEmittedValueParsesBackAsLua() throws {
        guard Self.luaAvailable else { return }

        let source = PersonalizationEvaluator.renderLuaDriverScript(
            staticVariables: [],
            expressions: [
                PersonalizationExpression(name: "n", expression: "7"),
                PersonalizationExpression(name: "f", expression: "1/3"),
                PersonalizationExpression(name: "s", expression: "'he said \"hi\"\\n'"),
                PersonalizationExpression(name: "t", expression: "{1, {2, 3}, 4}"),
                PersonalizationExpression(name: "b", expression: "true"),
            ]
        )
        let (code, stdout, stderr) = try Self.runLua(source, seed: "ff")
        #expect(code == 0, "driver failed: \(stderr)")
        let lastLine = stdout.split(separator: "\n").last.map(String.init) ?? ""
        let values = try #require(
            (try? JSONSerialization.jsonObject(with: Data(lastLine.utf8))) as? [String: String])

        for (name, literal) in values {
            let probe = "local v = \(literal)\n"
            let (rc, _, err) = try Self.runLua(probe)
            #expect(rc == 0, "the driver emitted unparseable Lua for `\(name)`: \(literal) — \(err)")
        }
    }

    /// The done-test item that has no other guard: one seed, two
    /// implementations. Both are run here on the same env var and compared.
    @Test func theDriverSeedEqualsTheGradingRuntimeSeed() throws {
        guard Self.luaAvailable else { return }

        // A realistic 64-hex-char assignment seed, plus edge cases: empty (no
        // seed set) and a short value.
        for seed in [String(repeating: "9f3c", count: 16), "", "ff", "0"] {
            let driverSource = """
                \(LuaPersonalizationRuntime.chickadeeSeedLuaSource)
                io.write(tostring(chickadee_seed()), "\\n")
                """
            let (dcode, dout, derr) = try Self.runLua(driverSource, seed: seed)
            #expect(dcode == 0, "driver seed failed: \(derr)")

            let runtimeSource = """
                local chickadee = require("test_runtime")
                io.write(tostring(chickadee.seed()), "\\n")
                """
            let (rcode, rout, rerr) = try Self.runLua(
                runtimeSource,
                extraFiles: ["test_runtime.lua": try Self.testRuntimeLuaSource()],
                seed: seed)
            #expect(rcode == 0, "runtime seed failed: \(rerr)")

            let driverSeed = dout.trimmingCharacters(in: .whitespacesAndNewlines)
            let runtimeSeed = rout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                driverSeed == runtimeSeed,
                """
                For CHICKADEE_ASSIGNMENT_SEED=\(seed.isEmpty ? "(unset)" : seed) the driver bound \
                \(driverSeed) but a graded script reads \(runtimeSeed). \
                `LuaPersonalizationRuntime.chickadeeSeedLuaSource` and `chickadee.seed()` in \
                Tools/runner-support/test_runtime.lua have diverged — an instructor's preview and \
                the student's grade would use different numbers, with nothing failing.
                """)
        }
    }

    /// The seed is also supposed to match R's, so a student's seed is one number
    /// whichever non-Python language the assignment is in. Both fold the same
    /// hex with Horner's method modulo 2^31-1.
    @Test func theLuaSeedMatchesTheDocumentedHornerFold() throws {
        guard Self.luaAvailable else { return }

        let seed = "abc123"
        let source = """
            \(LuaPersonalizationRuntime.chickadeeSeedLuaSource)
            io.write(tostring(chickadee_seed()), "\\n")
            """
        let (code, out, err) = try Self.runLua(source, seed: seed)
        #expect(code == 0, "driver failed: \(err)")

        // Computed here independently rather than by re-running the Lua, so
        // this asserts the reduction and not just its self-consistency.
        var expected = 0
        for character in seed.lowercased() {
            guard let digit = character.hexDigitValue else { continue }
            expected = (expected * 16 + digit) % 2_147_483_647
        }
        #expect(out.trimmingCharacters(in: .whitespacesAndNewlines) == String(expected))
    }
}
