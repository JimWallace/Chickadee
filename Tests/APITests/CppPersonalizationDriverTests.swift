// Tests/APITests/CppPersonalizationDriverTests.swift
//
// The C++ expression driver, run through the real evaluator (#1789).
//
// Three properties that reading the code cannot check, and each breaks as a
// wrong mark rather than a crash:
//
// 1. THE OUTPUT IS C++ SOURCE. The server writes each value verbatim into
//    `_ck_inputs.hpp`, so every value the driver emits must compile.
// 2. THE SEED THE DRIVER BINDS MUST EQUAL THE SEED A TEST READS.
//    `CppPersonalizationDriver.seedSource` and `ck::seed()` in
//    `test_runtime.hpp` are two copies of one fold (#1796). If they diverge, an
//    instructor's preview shows one set of values and the student's tests
//    grade against another, with nothing failing.
// 3. SUPPORT FILES LOAD, and an evaluation leaves nothing in the support
//    directory that the next one would include (#1788).

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(3))) struct CppPersonalizationDriverTests {

    private static func evaluate(
        _ expressions: [PersonalizationExpression], statics: [FamilyVariable] = [], seed: String = "ff",
        supportDirectory: URL? = nil
    ) async throws -> [String: String] {
        try await PersonalizationEvaluator.evaluate(
            seedHex: seed, staticVariables: statics, expressions: expressions,
            supportFilesDirectory: supportDirectory?.path, language: .cpp)
    }

    /// Compiles `program` beside the canonical runtime and runs it.
    private static func compileAndRun(_ program: String, seed: String) async throws -> ToolRun {
        let directory = try CompiledDriverFixtures.directory(
            "ck-cppdriver",
            files: ["test_runtime.hpp": try CompiledDriverFixtures.runtime("test_runtime.hpp"), "probe.cpp": program])
        defer { try? FileManager.default.removeItem(at: directory) }
        let compile = try await runTool(
            ["g++", "-std=c++20", "-O0", "probe.cpp", "-o", "probe"], workingDirectory: directory)
        guard compile.exitCode == 0 else { return compile }
        return try await runTool(
            [directory.appendingPathComponent("probe").path], workingDirectory: directory,
            extraEnvironment: ["CHICKADEE_ASSIGNMENT_SEED": seed])
    }

    @Test(.requiresGpp) func expressionsEvaluateInOrderAndEmitCppLiterals() async throws {
        let values = try await Self.evaluate(
            [
                PersonalizationExpression(name: "doubled", expression: "base * 2"),
                // Reads an earlier expression, so the driver must bind in order.
                PersonalizationExpression(name: "quadrupled", expression: "doubled * 2"),
                PersonalizationExpression(
                    name: "label", expression: "std::string(\"row \") + std::to_string(doubled)"),
                PersonalizationExpression(name: "ratio", expression: "doubled / 8.0"),
                PersonalizationExpression(name: "big", expression: "3000000000LL"),
                PersonalizationExpression(name: "flags", expression: "std::vector<bool>{true, false}"),
            ],
            statics: [FamilyVariable(name: "base", value: .int(10))])
        #expect(values["doubled"] == "20")
        #expect(values["quadrupled"] == "40")
        #expect(values["label"] == "std::string(\"row 20\")")
        #expect(values["ratio"] == "2.5")
        #expect(values["big"] == "3000000000LL", "a value past int32 keeps its suffix")
        #expect(values["flags"] == "std::vector<bool>{true, false}")
    }

    /// Every emitted value must compile, because it is written into
    /// `_ck_inputs.hpp` as it is.
    @Test(.requiresGpp) func everyEmittedValueCompilesAsCpp() async throws {
        let values = try await Self.evaluate([
            PersonalizationExpression(name: "n", expression: "7"),
            PersonalizationExpression(name: "f", expression: "1.0 / 3"),
            PersonalizationExpression(name: "whole", expression: "4.0"),
            PersonalizationExpression(name: "s", expression: "std::string(\"he said \\\"hi\\\"\\n\")"),
            PersonalizationExpression(name: "b", expression: "true"),
            PersonalizationExpression(name: "v", expression: "std::vector<long long>{1, 2, 3}"),
            PersonalizationExpression(
                name: "m", expression: "std::map<std::string, double>{{\"a\", 1.5}, {\"b\", 2.0}}"),
        ])
        let declarations = values.sorted { $0.key < $1.key }
            .map { "inline const auto ck_probe_\($0.key) = \($0.value);" }
        let program = (["#include \"test_runtime.hpp\""] + declarations + ["int main() { return 0; }"])
            .joined(separator: "\n")
        let run = try await Self.compileAndRun(program, seed: "ff")
        #expect(run.exitCode == 0, "an emitted value is not C++: \(values) — \(run.stderr)")
    }

    @Test(.requiresGpp) func theDriverSeedEqualsTheRuntimeSeed() async throws {
        for seed in CompiledDriverFixtures.seeds {
            let driver = try await Self.evaluate(
                [PersonalizationExpression(name: "s", expression: "seed")], seed: seed)
            let runtime = try await Self.compileAndRun(
                "#include \"test_runtime.hpp\"\nint main() { std::cout << ck::seed() << \"\\n\"; }",
                seed: seed)
            #expect(runtime.exitCode == 0, "the runtime probe failed: \(runtime.stderr)")
            let expected = String(CompiledDriverFixtures.hornerSeed(seed))
            #expect(driver["s"] == expected, "the driver bound \(driver["s"] ?? "nothing") for seed \"\(seed)\"")
            #expect(
                runtime.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected,
                "ck::seed() read \(runtime.stdout) for seed \"\(seed)\", but the driver binds \(expected)")
        }
    }

    /// A helper beside the assignment is included, and two evaluations in one
    /// support directory both work and leave it as they found it (#1788).
    @Test(.requiresGpp) func supportFilesLoadAndEvaluationsLeaveNothingBehind() async throws {
        let support = try CompiledDriverFixtures.directory(
            "ck-cppsupport", files: ["helper.hpp": "inline int twice(int x) { return 2 * x; }\n"])
        defer { try? FileManager.default.removeItem(at: support) }
        for _ in 0..<2 {
            let values = try await Self.evaluate(
                [PersonalizationExpression(name: "answer", expression: "twice(21)")], supportDirectory: support)
            #expect(values["answer"] == "42")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(left == ["helper.hpp"], "an evaluation left files in the support directory: \(left)")
    }
}
