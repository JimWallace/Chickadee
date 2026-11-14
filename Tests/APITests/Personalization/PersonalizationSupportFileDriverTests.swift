// Tests/APITests/Personalization/PersonalizationSupportFileDriverTests.swift
//
// The Lua and Octave personalization drivers with support files. The
// existing driver suites (`LuaPersonalizationDriverTests`,
// `OctavePersonalizationDriverTests`) render without helpers, and no test
// called `PersonalizationEvaluator.evaluate` for either language, so the
// helper-loading block of each driver and the per-language support-file
// selection had no coverage. The rendering tests need no interpreter; the
// evaluation tests run the real interpreter and carry its condition trait.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) final class PersonalizationSupportFileDriverTests {
    private let supportDir: URL

    init() throws {
        supportDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ck-personalize-support-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: supportDir, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: supportDir)
    }

    private func writeSupportFile(_ name: String, _ contents: String) throws {
        try contents.write(to: supportDir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    // MARK: - Rendering (no interpreter)

    @Test func theLuaDriverLoadsEachSupportFileInTheExpressionScope() throws {
        let source = PersonalizationEvaluator.renderLuaDriverScript(
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "n", expression: "1")],
            supportFiles: ["helpers.lua", "solution.lua"]
        )
        #expect(source.contains("-- Auto-loaded support files"))
        #expect(source.contains("do local chunk = loadfile(\"helpers.lua\", \"t\", scope)"))
        #expect(source.contains("do local chunk = loadfile(\"solution.lua\", \"t\", scope)"))
        // A broken helper is ignored, not fatal: the chunk runs under pcall.
        #expect(source.contains("   if chunk then pcall(chunk) end end"))
        // The helpers load in the order given, and before the expressions.
        let helpers = try #require(source.range(of: "loadfile(\"helpers.lua\""))
        let solution = try #require(source.range(of: "loadfile(\"solution.lua\""))
        let expressions = try #require(source.range(of: "-- Per-student expressions"))
        #expect(helpers.lowerBound < solution.lowerBound)
        #expect(solution.lowerBound < expressions.lowerBound)
    }

    @Test func theLuaDriverWithoutSupportFilesHasNoLoadBlock() {
        let source = PersonalizationEvaluator.renderLuaDriverScript(
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "n", expression: "1")]
        )
        #expect(!source.contains("-- Auto-loaded support files"))
        #expect(!source.contains("loadfile("))
    }

    @Test func theOctaveDriverEvaluatesEachSupportFileBehindAScriptGuard() throws {
        let source = PersonalizationEvaluator.renderOctaveDriverScript(
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "n", expression: "1")],
            supportFiles: ["triple.m"]
        )
        #expect(source.contains("% Auto-loaded support files"))
        #expect(source.contains("    eval([\"1;\" sprintf(\"\\n\") fileread(\"triple.m\")]);"))
        // Each helper sits in its own try/catch, so a broken one is ignored.
        let lines = source.components(separatedBy: "\n")
        let evalIndex = try #require(lines.firstIndex { $0.contains("fileread(\"triple.m\")") })
        #expect(lines[evalIndex - 1] == "try")
        #expect(lines[evalIndex + 1] == "catch")
        #expect(lines[evalIndex + 2] == "end")
    }

    @Test func theOctaveDriverWithoutSupportFilesHasNoLoadBlock() {
        let source = PersonalizationEvaluator.renderOctaveDriverScript(
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "n", expression: "1")]
        )
        #expect(!source.contains("% Auto-loaded support files"))
        #expect(!source.contains("fileread("))
    }

    // MARK: - Evaluation (real interpreter)

    /// A `.lua` helper beside the assignment is loaded by file, so an
    /// expression can call its function. A broken helper and a file in
    /// another language do not stop the evaluation, and a hidden `.lua` file
    /// is not loaded.
    @Test(.requiresLua) func aLuaExpressionCallsASupportHelper() async throws {
        try writeSupportFile("helpers.lua", "function triple(x) return x * 3 end\n")
        try writeSupportFile("broken.lua", "function (\n")
        try writeSupportFile("notes.py", "raise SystemExit(3)\n")
        try writeSupportFile(".hidden.lua", "hidden_marker = true\n")

        let values = try await PersonalizationEvaluator.evaluate(
            seedHex: "0001",
            staticVariables: [FamilyVariable(name: "base", value: .int(7))],
            expressions: [
                PersonalizationExpression(name: "tripled", expression: "triple(base)"),
                PersonalizationExpression(name: "markerType", expression: "type(hidden_marker)"),
            ],
            supportFilesDirectory: supportDir.path,
            language: .lua,
            timeoutSeconds: 30
        )
        #expect(values["tripled"] == "21")
        #expect(values["markerType"] == "\"nil\"")
    }

    /// The helper file is named `helpers.m`, not `triple.m`, so Octave cannot
    /// autoload `triple` from the working directory: the call works only when
    /// the driver's load block registered it. A broken helper is caught and
    /// ignored.
    @Test(.requiresOctave) func anOctaveExpressionCallsASupportHelper() async throws {
        try writeSupportFile("helpers.m", "function y = triple(x)\n  y = 3 * x;\nend\n")
        try writeSupportFile("broken.m", "function (\n")

        let values = try await PersonalizationEvaluator.evaluate(
            seedHex: "0001",
            staticVariables: [FamilyVariable(name: "base", value: .int(7))],
            expressions: [PersonalizationExpression(name: "tripled", expression: "triple(base)")],
            supportFilesDirectory: supportDir.path,
            language: .octave,
            timeoutSeconds: 60
        )
        #expect(values["tripled"] == "21")
    }
}
