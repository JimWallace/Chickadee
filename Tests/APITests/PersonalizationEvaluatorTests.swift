// Tests/APITests/PersonalizationEvaluatorTests.swift
//
// Slice 2 of issue #461 — exercises the server-side Python evaluator
// that resolves per-student personalization expressions.  Runs a real
// `python3` subprocess in each test (mirrors the Phase 1 worker tests).

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct PersonalizationEvaluatorTests {

    // MARK: - Driver-script rendering

    @Test func driver_bindsSeedFromEnv() {
        let src = PersonalizationEvaluator.renderDriverScript(
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "x", expression: "seed % 7")]
        )
        #expect(src.contains("seed = int(os.environ['CHICKADEE_ASSIGNMENT_SEED'], 16)"))
        #expect(src.contains("x = (seed % 7)"))
        #expect(src.contains("_out['x'] = repr(x)"))
        #expect(src.contains("print(json.dumps(_out))"))
    }

    @Test func driver_emitsStaticVariablesBeforeExpressions() throws {
        let src = PersonalizationEvaluator.renderDriverScript(
            staticVariables: [FamilyVariable(name: "q", value: .array([.string("a"), .string("b")]))],
            expressions: [PersonalizationExpression(name: "pick", expression: "q[seed % len(q)]")]
        )
        let qRange = try #require(
            src.range(of: "q = "),
            "Expected q assignment in driver source"
        )
        let pickRange = try #require(
            src.range(of: "pick = (q[seed % len(q)])"),
            "Expected pick expression in driver source"
        )
        #expect(
            qRange.lowerBound < pickRange.lowerBound,
            "Static vars must appear before expressions so expressions can reference them"
        )
    }

    // MARK: - End-to-end evaluation

    @Test func evaluate_emptyExpressionsReturnsEmpty() async throws {
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: String(repeating: "a", count: 64),
            staticVariables: [],
            expressions: []
        )
        #expect(result.isEmpty)
    }

    @Test func evaluate_simpleArithmetic() async throws {
        // seed = int("aaaa", 16) = 43690.  43690 % 26 = 10.
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "aaaa",
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "shift", expression: "seed % 26")]
        )
        #expect(result["shift"] == "10")
    }

    @Test func evaluate_referencesStaticVariable() async throws {
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0001",
            staticVariables: [
                FamilyVariable(
                    name: "quotes",
                    value: .array([.string("foo"), .string("bar"), .string("baz")]))
            ],
            expressions: [
                PersonalizationExpression(name: "pick", expression: "quotes[seed % len(quotes)]")
            ]
        )
        // seed = 1; 1 % 3 = 1; quotes[1] = "bar".
        #expect(result["pick"] == "'bar'")
    }

    @Test func evaluate_referencesPriorExpression() async throws {
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0010",
            staticVariables: [],
            expressions: [
                PersonalizationExpression(name: "shift", expression: "seed % 26"),
                PersonalizationExpression(name: "doubled", expression: "shift * 2"),
            ]
        )
        // seed = 16; 16 % 26 = 16; 16 * 2 = 32.
        #expect(result["shift"] == "16")
        #expect(result["doubled"] == "32")
    }

    @Test func evaluate_nonZeroExitSurfacesAsError() async {
        do {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: "0001",
                staticVariables: [],
                expressions: [PersonalizationExpression(name: "x", expression: "1/0")]
            )
            Issue.record("Expected nonZeroExit")
        } catch PersonalizationEvaluatorError.nonZeroExit(_, let stderr) {
            #expect(
                stderr.contains("ZeroDivisionError"),
                "stderr should carry the Python traceback; got: \(stderr)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func evaluate_undeclaredNameSurfacesAsError() async {
        do {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: "0001",
                staticVariables: [],
                expressions: [PersonalizationExpression(name: "x", expression: "undeclared_thing")]
            )
            Issue.record("Expected nonZeroExit")
        } catch PersonalizationEvaluatorError.nonZeroExit(_, let stderr) {
            #expect(
                stderr.contains("NameError"),
                "stderr should mention NameError; got: \(stderr)")
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test func evaluate_reprStringIsValidPythonLiteral() async throws {
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "abc1",
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "msg", expression: "f\"hello {seed % 10}\"")]
        )
        // Result should be a Python string literal — single-quoted by repr.
        let v = result["msg"] ?? ""
        #expect(v.hasPrefix("'") && v.hasSuffix("'"), "Expected single-quoted string literal; got: \(v)")
    }

    // MARK: - Personalization plumbing on TestProperties

    @Test func testProperties_globalExpressionsRoundTrip() throws {
        let props = TestProperties(
            globalExpressions: [
                PersonalizationExpression(name: "shift", expression: "seed % 26"),
                PersonalizationExpression(name: "msg", expression: "f'hi {shift}'"),
            ]
        )
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        #expect(decoded.globalExpressions.count == 2)
        #expect(decoded.globalExpressions[0].name == "shift")
        #expect(decoded.globalExpressions[1].expression == "f'hi {shift}'")
    }

    @Test func testProperties_runnerSanitizedStripsExpressions() {
        let props = TestProperties(
            globalExpressions: [PersonalizationExpression(name: "x", expression: "seed % 2")]
        )
        let sanitized = props.runnerSanitized()
        #expect(
            sanitized.globalExpressions.isEmpty,
            "Expressions are a server-side authoring concern; runner shouldn't see them.")
    }

    @Test func testProperties_missingGlobalExpressionsDecodesEmpty() throws {
        let json = Data(
            #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}
            """#.utf8)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: json)
        #expect(decoded.globalExpressions.isEmpty)
    }
}
