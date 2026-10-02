// Tests/APITests/JavaPersonalizationDriverTests.swift
//
// The Java expression driver, run through the real evaluator (#1789). The same
// three properties as `CppPersonalizationDriverTests`: the output is Java
// source written verbatim into `_ck_inputs.java`, the seed the driver binds
// equals `ck.seed()` in `test_runtime.java` (#1796), and support files load
// without leaving anything behind (#1788).

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(3))) struct JavaPersonalizationDriverTests {

    private static func evaluate(
        _ expressions: [PersonalizationExpression], statics: [FamilyVariable] = [], seed: String = "ff",
        supportDirectory: URL? = nil
    ) async throws -> [String: String] {
        try await PersonalizationEvaluator.evaluate(
            seedHex: seed, staticVariables: statics, expressions: expressions,
            supportFilesDirectory: supportDirectory?.path, language: .java)
    }

    /// Compiles `Probe.java` beside the canonical runtime and runs it.
    private static func compileAndRun(probe: String, seed: String) async throws -> ToolRun {
        let directory = try CompiledDriverFixtures.directory(
            "ck-javadriver",
            files: ["test_runtime.java": try CompiledDriverFixtures.runtime("test_runtime.java"), "Probe.java": probe])
        defer { try? FileManager.default.removeItem(at: directory) }
        let compile = try await runTool(
            ["javac", "-encoding", "UTF-8", "-d", "out", "test_runtime.java", "Probe.java"],
            workingDirectory: directory)
        guard compile.exitCode == 0 else { return compile }
        return try await runTool(
            ["java", "-cp", "out", "Probe"], workingDirectory: directory,
            extraEnvironment: ["CHICKADEE_ASSIGNMENT_SEED": seed])
    }

    @Test(.requiresJavac) func expressionsEvaluateInOrderAndEmitJavaLiterals() async throws {
        let values = try await Self.evaluate(
            [
                PersonalizationExpression(name: "doubled", expression: "base * 2"),
                // Reads an earlier expression, so the driver must bind in order.
                PersonalizationExpression(name: "quadrupled", expression: "doubled * 2"),
                PersonalizationExpression(name: "label", expression: "\"row \" + doubled"),
                PersonalizationExpression(name: "ratio", expression: "doubled / 8.0"),
                PersonalizationExpression(name: "big", expression: "3000000000L"),
                PersonalizationExpression(name: "flag", expression: "doubled > 10"),
            ],
            statics: [FamilyVariable(name: "base", value: .int(10))])
        #expect(values["doubled"] == "20")
        #expect(values["quadrupled"] == "40")
        #expect(values["label"] == "\"row 20\"")
        #expect(values["ratio"] == "2.5")
        #expect(values["big"] == "3000000000L", "a value past int32 keeps its suffix")
        #expect(values["flag"] == "true")
    }

    /// Every emitted value must compile, because it is written into
    /// `_ck_inputs.java` as it is.
    @Test(.requiresJavac) func everyEmittedValueCompilesAsJava() async throws {
        let values = try await Self.evaluate([
            PersonalizationExpression(name: "n", expression: "7"),
            PersonalizationExpression(name: "f", expression: "1.0 / 3"),
            PersonalizationExpression(name: "whole", expression: "4.0"),
            PersonalizationExpression(name: "s", expression: "\"he said \\\"hi\\\"\\n\""),
            PersonalizationExpression(name: "list", expression: "java.util.List.of(1, 2, 3)"),
            PersonalizationExpression(name: "map", expression: "java.util.Map.of(\"a\", 1.5)"),
        ])
        let declarations = values.sorted { $0.key < $1.key }
            .map { "        var ckProbe_\($0.key) = \($0.value);" }
        let probe =
            (["class Probe {", "    public static void main(String[] args) {"] + declarations + ["    }", "}"])
            .joined(separator: "\n")
        let run = try await Self.compileAndRun(probe: probe, seed: "ff")
        #expect(run.exitCode == 0, "an emitted value is not Java: \(values) — \(run.stderr)")
    }

    @Test(.requiresJavac) func theDriverSeedEqualsTheRuntimeSeed() async throws {
        for seed in CompiledDriverFixtures.seeds {
            let driver = try await Self.evaluate(
                [PersonalizationExpression(name: "s", expression: "seed")], seed: seed)
            let runtime = try await Self.compileAndRun(
                probe: "class Probe { public static void main(String[] args) { System.out.println(ck.seed()); } }",
                seed: seed)
            #expect(runtime.exitCode == 0, "the runtime probe failed: \(runtime.stderr)")
            let expected = String(CompiledDriverFixtures.hornerSeed(seed))
            #expect(driver["s"] == expected, "the driver bound \(driver["s"] ?? "nothing") for seed \"\(seed)\"")
            #expect(
                runtime.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected,
                "ck.seed() read \(runtime.stdout) for seed \"\(seed)\", but the driver binds \(expected)")
        }
    }

    /// A helper beside the assignment is compiled with the driver, and two
    /// evaluations in one support directory both work and leave it as they
    /// found it (#1788).
    @Test(.requiresJavac) func supportFilesLoadAndEvaluationsLeaveNothingBehind() async throws {
        let support = try CompiledDriverFixtures.directory(
            "ck-javasupport",
            files: ["Helper.java": "class Helper {\n    static int twice(int x) { return 2 * x; }\n}\n"])
        defer { try? FileManager.default.removeItem(at: support) }
        for _ in 0..<2 {
            let values = try await Self.evaluate(
                [PersonalizationExpression(name: "answer", expression: "Helper.twice(21)")],
                supportDirectory: support)
            #expect(values["answer"] == "42")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(left == ["Helper.java"], "an evaluation left files in the support directory: \(left)")
    }
}
