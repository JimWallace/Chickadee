// Tests/APITests/PersonalizationEvaluatorTests.swift
//
// Slice 2 of issue #461 — exercises the server-side Python evaluator
// that resolves per-student personalization expressions.  Runs a real
// `python3` subprocess in each test (mirrors the Phase 1 worker tests).

import Core
import Foundation
import XCTest

@testable import chickadee_server

final class PersonalizationEvaluatorTests: XCTestCase {

    // MARK: - Driver-script rendering

    func testDriver_bindsSeedFromEnv() {
        let src = PersonalizationEvaluator.renderDriverScript(
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "x", expression: "seed % 7")]
        )
        XCTAssertTrue(src.contains("seed = int(os.environ['CHICKADEE_ASSIGNMENT_SEED'], 16)"))
        XCTAssertTrue(src.contains("x = (seed % 7)"))
        XCTAssertTrue(src.contains("_out['x'] = repr(x)"))
        XCTAssertTrue(src.contains("print(json.dumps(_out))"))
    }

    func testDriver_emitsStaticVariablesBeforeExpressions() {
        let src = PersonalizationEvaluator.renderDriverScript(
            staticVariables: [FamilyVariable(name: "q", value: .array([.string("a"), .string("b")]))],
            expressions: [PersonalizationExpression(name: "pick", expression: "q[seed % len(q)]")]
        )
        guard let qRange = src.range(of: "q = "),
            let pickRange = src.range(of: "pick = (q[seed % len(q)])")
        else {
            XCTFail("Expected both q assignment and pick expression in driver source")
            return
        }
        XCTAssertLessThan(
            qRange.lowerBound, pickRange.lowerBound,
            "Static vars must appear before expressions so expressions can reference them")
    }

    // MARK: - End-to-end evaluation

    func testEvaluate_emptyExpressionsReturnsEmpty() async throws {
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: String(repeating: "a", count: 64),
            staticVariables: [],
            expressions: []
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testEvaluate_simpleArithmetic() async throws {
        // seed = int("aaaa", 16) = 43690.  43690 % 26 = 10.
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "aaaa",
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "shift", expression: "seed % 26")]
        )
        XCTAssertEqual(result["shift"], "10")
    }

    func testEvaluate_referencesStaticVariable() async throws {
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
        XCTAssertEqual(result["pick"], "'bar'")
    }

    func testEvaluate_referencesPriorExpression() async throws {
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0010",
            staticVariables: [],
            expressions: [
                PersonalizationExpression(name: "shift", expression: "seed % 26"),
                PersonalizationExpression(name: "doubled", expression: "shift * 2"),
            ]
        )
        // seed = 16; 16 % 26 = 16; 16 * 2 = 32.
        XCTAssertEqual(result["shift"], "16")
        XCTAssertEqual(result["doubled"], "32")
    }

    func testEvaluate_nonZeroExitSurfacesAsError() async {
        do {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: "0001",
                staticVariables: [],
                expressions: [PersonalizationExpression(name: "x", expression: "1/0")]
            )
            XCTFail("Expected nonZeroExit")
        } catch PersonalizationEvaluatorError.nonZeroExit(_, let stderr) {
            XCTAssertTrue(
                stderr.contains("ZeroDivisionError"),
                "stderr should carry the Python traceback; got: \(stderr)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEvaluate_undeclaredNameSurfacesAsError() async {
        do {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: "0001",
                staticVariables: [],
                expressions: [PersonalizationExpression(name: "x", expression: "undeclared_thing")]
            )
            XCTFail("Expected nonZeroExit")
        } catch PersonalizationEvaluatorError.nonZeroExit(_, let stderr) {
            XCTAssertTrue(
                stderr.contains("NameError"),
                "stderr should mention NameError; got: \(stderr)")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testEvaluate_reprStringIsValidPythonLiteral() async throws {
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "abc1",
            staticVariables: [],
            expressions: [PersonalizationExpression(name: "msg", expression: "f\"hello {seed % 10}\"")]
        )
        // Result should be a Python string literal — single-quoted by repr.
        let v = result["msg"] ?? ""
        XCTAssertTrue(v.hasPrefix("'") && v.hasSuffix("'"), "Expected single-quoted string literal; got: \(v)")
    }

    // MARK: - Personalization plumbing on TestProperties

    func testTestProperties_globalExpressionsRoundTrip() throws {
        let props = TestProperties(
            globalExpressions: [
                PersonalizationExpression(name: "shift", expression: "seed % 26"),
                PersonalizationExpression(name: "msg", expression: "f'hi {shift}'"),
            ]
        )
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        XCTAssertEqual(decoded.globalExpressions.count, 2)
        XCTAssertEqual(decoded.globalExpressions[0].name, "shift")
        XCTAssertEqual(decoded.globalExpressions[1].expression, "f'hi {shift}'")
    }

    func testTestProperties_runnerSanitizedStripsExpressions() {
        let props = TestProperties(
            globalExpressions: [PersonalizationExpression(name: "x", expression: "seed % 2")]
        )
        let sanitized = props.runnerSanitized()
        XCTAssertEqual(
            sanitized.globalExpressions.count, 0,
            "Expressions are a server-side authoring concern; runner shouldn't see them.")
    }

    func testTestProperties_missingGlobalExpressionsDecodesEmpty() throws {
        let json = #"""
            {"schemaVersion":1,"testSuites":[],"timeLimitSeconds":10}
            """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TestProperties.self, from: json)
        XCTAssertEqual(decoded.globalExpressions.count, 0)
    }
}
