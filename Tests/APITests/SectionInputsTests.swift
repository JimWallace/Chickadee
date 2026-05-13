// Tests/APITests/SectionInputsTests.swift
//
// Slice 4 of issue #461 — section variables can carry per-student
// expressions (parity with Slice 2's global expressions).  These tests
// focus on the schema + evaluator-integration surface; the JS
// classification logic mirrors `Public/global-inputs-editor.js` and
// is covered by the global-inputs unit tests in spirit.

import XCTest
@testable import chickadee_server
import Core
import Foundation

final class SectionInputsTests: XCTestCase {

    // MARK: - Schema round-trip

    func testSection_expressionsRoundTrip() throws {
        let section = TestSuiteSection(
            id: "sec1",
            name: "Question 1",
            variables: [FamilyVariable(name: "lit", value: .int(42))],
            expressions: [
                PersonalizationExpression(name: "shift", expression: "seed % 26"),
                PersonalizationExpression(name: "msg",   expression: "f'shift is {shift}'")
            ]
        )
        let data = try JSONEncoder().encode(section)
        let decoded = try JSONDecoder().decode(TestSuiteSection.self, from: data)
        XCTAssertEqual(decoded.variables.count, 1)
        XCTAssertEqual(decoded.expressions.count, 2)
        XCTAssertEqual(decoded.expressions[0].name, "shift")
        XCTAssertEqual(decoded.expressions[1].expression, "f'shift is {shift}'")
    }

    func testSection_missingExpressionsDecodesAsEmpty() throws {
        let json = #"""
        {"id":"abc","name":"Sec","variables":[]}
        """#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(TestSuiteSection.self, from: json)
        XCTAssertEqual(decoded.expressions.count, 0)
    }

    // MARK: - Manifest-level encoding

    func testTestProperties_sectionExpressionsRoundTripThroughManifest() throws {
        let section = TestSuiteSection(
            id: "s1", name: "Q1",
            expressions: [PersonalizationExpression(name: "shift", expression: "seed % 13")]
        )
        let props = TestProperties(sections: [section])
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        XCTAssertEqual(decoded.sections.count, 1)
        XCTAssertEqual(decoded.sections[0].expressions.count, 1)
        XCTAssertEqual(decoded.sections[0].expressions[0].name, "shift")
    }

    func testTestProperties_runnerSanitizedKeepsSectionExpressions() {
        // Section expressions are kept on the runner-facing manifest
        // because the runner doesn't choke on them (FamilyVariable +
        // PersonalizationExpression are stable Codable types).  This
        // mirrors the kept-vs-stripped policy for globalVariables.
        let section = TestSuiteSection(
            id: "s1", name: "Q1",
            expressions: [PersonalizationExpression(name: "x", expression: "seed % 2")]
        )
        let props = TestProperties(sections: [section])
        let sanitized = props.runnerSanitized()
        XCTAssertEqual(sanitized.sections.count, 1)
        XCTAssertEqual(sanitized.sections[0].expressions.count, 1)
    }

    // MARK: - End-to-end evaluator integration

    func testEvaluator_acceptsSectionExpressions() async throws {
        // The evaluator is kind-agnostic — section + global expressions
        // are concatenated and evaluated as one ordered list before
        // notebook substitution.  This test confirms a section
        // expression that references a global variable evaluates
        // correctly.
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0010",
            staticVariables: [
                FamilyVariable(name: "quotes",
                               value: .array([.string("alpha"), .string("beta"), .string("gamma")]))
            ],
            expressions: [
                // Imagine this came from a section's expressions list.
                PersonalizationExpression(name: "pick", expression: "quotes[seed % len(quotes)]")
            ]
        )
        // seed = 0x0010 = 16; 16 % 3 = 1; quotes[1] = "beta".
        XCTAssertEqual(result["pick"], "'beta'")
    }
}
