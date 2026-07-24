// Tests/APITests/PersonalizationEvaluatorRTests.swift
//
// R-language coverage for the per-student expression evaluator (R support for
// the personalization engine). Two layers:
//
//   1. `renderRDriverScript` byte-shape assertions — CI-safe, no interpreter
//      needed. Pins that the R driver binds the seed via the shared Core
//      `chickadee_seed()`, renders statics via `rLiteral`, evaluates each
//      expression, and emits the JSON map as its last line.
//   2. A real `Rscript` round-trip — spawns the actual driver and asserts the
//      seed math, `rLiteral` binding, and `deparse` → JSON → Swift decode chain
//      produce the expected R literals. Silently skipped where `Rscript` is
//      absent (most CI hosts); it runs in the r-base container and locally.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct PersonalizationEvaluatorRRenderTests {

    @Test func rDriverBindsSeedStaticsAndExpressions() {
        let pool = FamilyVariable(
            name: "pool",
            value: .array([.string("AACGT"), .string("GGTTA"), .string("CCGAT"), .string("TTAGC")]))
        let expr = PersonalizationExpression(
            name: "sample1_reads", expression: "pool[(seed %% 4) + 1]")

        let script = PersonalizationEvaluator.renderRDriverScript(
            staticVariables: [pool], expressions: [expr])

        // Seed primitive comes from the one Core source of truth (so the driver
        // and the grading runtime compute the seed identically).
        #expect(script.contains("chickadee_seed <- function()"))
        #expect(script.contains("seed <- chickadee_seed()"))
        // Static rendered via rLiteral (a homogeneous string array → c(...)).
        #expect(script.contains("`pool` <- c(\"AACGT\", \"GGTTA\", \"CCGAT\", \"TTAGC\")"))
        // Expression bound in declared order, back-tick quoted.
        #expect(script.contains("`sample1_reads` <- (pool[(seed %% 4) + 1])"))
        // Emit stage: a JSON map keyed by expression name, deparse'd value.
        #expect(script.contains(".ck_json_str(\"sample1_reads\")"))
        #expect(script.contains("cat(paste0(\"{\""))
    }

    @Test func rDriverSourcesSupportFiles() {
        let script = PersonalizationEvaluator.renderRDriverScript(
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "x", expression: "1L")],
            supportFiles: ["solution.R", "helpers.R"])
        #expect(script.contains("tryCatch(source(\"solution.R\"), error = function(e) NULL)"))
        #expect(script.contains("tryCatch(source(\"helpers.R\"), error = function(e) NULL)"))
    }

    /// The Python driver must stay byte-for-byte what it was — the R work
    /// defaults `language` to `.python`, so no existing caller changes shape.
    @Test func pythonDriverUnchangedByDefault() {
        let expr = PersonalizationExpression(name: "x", expression: "seed % 3")
        let script = PersonalizationEvaluator.renderDriverScript(
            staticVariables: [], expressions: [expr])
        #expect(script.contains("seed = int(os.environ['CHICKADEE_ASSIGNMENT_SEED'], 16)"))
        #expect(script.contains("x = (seed % 3)"))
        #expect(script.contains("print(json.dumps(_out))"))
    }
}

@Suite(.serialized) struct PersonalizationEvaluatorREvalTests {

    /// True when `Rscript` is on PATH. The evaluator spawns via `/usr/bin/env`,
    /// so this probe uses the same resolution.
    private static var hasRscript: Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = ["Rscript", "--version"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus == 0
        } catch {
            return false
        }
    }

    /// The base-R seed reduction, mirrored in Swift so the test pins the exact
    /// resolved value (not just "one of the pool"). Horner-fold of the hex
    /// digits modulo 2^31-1 — identical to `RPersonalizationRuntime.chickadeeSeedRSource`.
    private static func rSeed(_ hex: String) -> Int {
        let modulus = 2_147_483_647
        var acc = 0
        for ch in hex.lowercased() {
            guard let digit = ch.hexDigitValue else { continue }
            acc = (acc * 16 + digit) % modulus
        }
        return acc
    }

    @Test func evaluatesRotationExpressionForSeed() async throws {
        guard Self.hasRscript else { return }  // silent skip where R is absent

        let poolStrings = ["AACGT", "GGTTA", "CCGAT", "TTAGC"]
        let pool = FamilyVariable(name: "pool", value: .array(poolStrings.map(JSONValue.string)))
        let expr = PersonalizationExpression(
            name: "sample1_reads", expression: "pool[(seed %% 4) + 1]")
        let seedHex = "a3f8c1029b7e4d6501234567890abcdeffedcba9876543210aabbccddeeff001"

        let out = try await PersonalizationEvaluator.evaluate(
            seedHex: seedHex,
            staticVariables: [pool],
            expressions: [expr],
            language: .r)

        // Expected element: R is 1-based, `(seed %% 4) + 1` → poolStrings[seed % 4].
        let expected = poolStrings[Self.rSeed(seedHex) % 4]
        // deparse of an R string is the double-quoted literal.
        #expect(out["sample1_reads"] == "\"\(expected)\"")
    }

    /// A value with quotes, a newline, a tab and a backslash must survive
    /// `deparse` → JSON → `JSONSerialization` intact as a re-parseable R literal.
    @Test func escapesNastyStringValues() async throws {
        guard Self.hasRscript else { return }

        let expr = PersonalizationExpression(
            name: "note", expression: #"paste0("q:\"x\"", "\n\t", "b \\ c")"#)
        let out = try await PersonalizationEvaluator.evaluate(
            seedHex: "01", staticVariables: [], expressions: [expr], language: .r)

        let literal = try #require(out["note"])
        // It's a quoted R string literal…
        #expect(literal.hasPrefix("\"") && literal.hasSuffix("\""))
        // …and it re-parses in R back to the original characters.
        #expect(literal.contains(#"\""#))  // escaped inner quote
        #expect(literal.contains(#"\n"#))  // escaped newline
        #expect(literal.contains(#"\\"#))  // escaped backslash
    }

    /// No expressions → no spawn, empty map (the early-return contract holds
    /// for R just as for Python).
    @Test func noExpressionsReturnsEmpty() async throws {
        let out = try await PersonalizationEvaluator.evaluate(
            seedHex: "01",
            staticVariables: [FamilyVariable(name: "x", value: .int(1))],
            expressions: [],
            language: .r)
        #expect(out.isEmpty)
    }
}
