// Tests/APITests/RacketPersonalizationDriverTests.swift
//
// The Racket expression driver, run through the real evaluator (#1789). The
// same three properties as `CppPersonalizationDriverTests`: the output is
// Racket source written verbatim into `_ck_inputs.rkt`, the seed the driver
// binds equals `chickadee-seed` in `test_runtime.rkt` (#1796), and support
// files load without leaving anything behind.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(3))) struct RacketPersonalizationDriverTests {

    private static func evaluate(
        _ expressions: [PersonalizationExpression], statics: [FamilyVariable] = [], seed: String = "ff",
        supportDirectory: URL? = nil
    ) async throws -> [String: String] {
        try await PersonalizationEvaluator.evaluate(
            seedHex: seed, staticVariables: statics, expressions: expressions,
            supportFilesDirectory: supportDirectory?.path, language: .racket)
    }

    /// Runs `probe.rkt` beside the canonical runtime.
    private static func run(probe: String, seed: String) async throws -> ToolRun {
        let directory = try CompiledDriverFixtures.directory(
            "ck-racketdriver",
            files: ["test_runtime.rkt": try CompiledDriverFixtures.runtime("test_runtime.rkt"), "probe.rkt": probe])
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await runTool(
            ["racket", "probe.rkt"], workingDirectory: directory,
            extraEnvironment: ["CHICKADEE_ASSIGNMENT_SEED": seed])
    }

    @Test(.requiresRacket) func expressionsEvaluateInOrderAndEmitRacketLiterals() async throws {
        let values = try await Self.evaluate(
            [
                PersonalizationExpression(name: "doubled", expression: "(* base 2)"),
                // Reads an earlier expression, so the driver must bind in order.
                PersonalizationExpression(name: "quadrupled", expression: "(* doubled 2)"),
                PersonalizationExpression(
                    name: "label", expression: "(string-append \"row \" (number->string doubled))"),
                PersonalizationExpression(name: "ratio", expression: "(/ doubled 8.0)"),
                PersonalizationExpression(name: "values", expression: "(list 1 2.5 \"three\")"),
                PersonalizationExpression(name: "flag", expression: "(> doubled 10)"),
            ],
            statics: [FamilyVariable(name: "base", value: .int(10))])
        #expect(values["doubled"] == "20")
        #expect(values["quadrupled"] == "40")
        #expect(values["label"] == "\"row 20\"")
        #expect(values["ratio"] == "2.5")
        #expect(values["values"] == "(list 1 2.5 \"three\")")
        #expect(values["flag"] == "#t")
    }

    /// Every emitted value must read back as Racket, because it is written into
    /// `_ck_inputs.rkt` as it is.
    @Test(.requiresRacket) func everyEmittedValueReadsBackAsRacket() async throws {
        let values = try await Self.evaluate([
            PersonalizationExpression(name: "n", expression: "7"),
            PersonalizationExpression(name: "f", expression: "(/ 1.0 3)"),
            PersonalizationExpression(name: "s", expression: "\"he said \\\"hi\\\"\\n\""),
            PersonalizationExpression(name: "nested", expression: "(list 1 (list 2 3) 4)"),
            PersonalizationExpression(name: "table", expression: "(hash \"a\" 1.5 \"b\" (list 2))"),
            PersonalizationExpression(name: "b", expression: "#f"),
        ])
        let definitions = values.sorted { $0.key < $1.key }.map { "(define ck-probe-\($0.key) \($0.value))" }
        let run = try await Self.run(probe: (["#lang racket"] + definitions).joined(separator: "\n"), seed: "ff")
        #expect(run.exitCode == 0, "an emitted value is not Racket: \(values) — \(run.stderr)")
    }

    @Test(.requiresRacket) func theDriverSeedEqualsTheRuntimeSeed() async throws {
        for seed in CompiledDriverFixtures.seeds {
            let driver = try await Self.evaluate(
                [PersonalizationExpression(name: "s", expression: "seed")], seed: seed)
            let runtime = try await Self.run(
                probe: "#lang racket\n(require \"test_runtime.rkt\")\n(displayln (chickadee-seed))", seed: seed)
            #expect(runtime.exitCode == 0, "the runtime probe failed: \(runtime.stderr)")
            let expected = String(CompiledDriverFixtures.hornerSeed(seed))
            #expect(driver["s"] == expected, "the driver bound \(driver["s"] ?? "nothing") for seed \"\(seed)\"")
            #expect(
                runtime.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == expected,
                "(chickadee-seed) read \(runtime.stdout) for seed \"\(seed)\", but the driver binds \(expected)")
        }
    }

    /// The driver starts from `racket/base`. The full `racket` language more
    /// than doubles its start-up, and under a loaded CI runner that pushed one
    /// evaluation past the evaluator's 5-second limit.
    @Test func theDriverStartsFromTheBaseLanguage() {
        let source = RacketPersonalizationDriver.render(
            staticVariables: [], expressions: [PersonalizationExpression(name: "s", expression: "seed")],
            supportFiles: [])
        #expect(source.hasPrefix("#lang racket/base\n"), "the driver starts with \(source.prefix(40))")
    }

    /// A helper beside the assignment is loaded into the expression namespace,
    /// and two evaluations in one support directory both work and leave it as
    /// they found it.
    @Test(.requiresRacket) func supportFilesLoadAndEvaluationsLeaveNothingBehind() async throws {
        let support = try CompiledDriverFixtures.directory(
            "ck-racketsupport",
            files: ["helper.rkt": "#lang racket\n(provide twice)\n(define (twice x) (* 2 x))\n"])
        defer { try? FileManager.default.removeItem(at: support) }
        for _ in 0..<2 {
            let values = try await Self.evaluate(
                [PersonalizationExpression(name: "answer", expression: "(twice 21)")], supportDirectory: support)
            #expect(values["answer"] == "42")
        }
        let left = try FileManager.default.contentsOfDirectory(atPath: support.path)
        #expect(left == ["helper.rkt"], "an evaluation left files in the support directory: \(left)")
    }
}
