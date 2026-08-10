// Tests/APITests/SectionInputsTests.swift
//
// Slice 4 of issue #461 — section variables can carry per-student
// expressions (parity with Slice 2's global expressions).  These tests
// focus on the schema + evaluator-integration surface; the JS
// classification logic mirrors `Public/global-inputs-editor.js` and
// is covered by the global-inputs unit tests in spirit.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite struct SectionInputsTests {

    // MARK: - Schema round-trip

    @Test func section_expressionsRoundTrip() throws {
        let section = TestSuiteSection(
            id: "sec1",
            name: "Question 1",
            variables: [FamilyVariable(name: "lit", value: .int(42))],
            expressions: [
                PersonalizationExpression(name: "shift", expression: "seed % 26"),
                PersonalizationExpression(name: "msg", expression: "f'shift is {shift}'"),
            ]
        )
        let data = try JSONEncoder().encode(section)
        let decoded = try JSONDecoder().decode(TestSuiteSection.self, from: data)
        #expect(decoded.variables.count == 1)
        #expect(decoded.expressions.count == 2)
        #expect(decoded.expressions[0].name == "shift")
        #expect(decoded.expressions[1].expression == "f'shift is {shift}'")
    }

    @Test func section_missingExpressionsDecodesAsEmpty() throws {
        let json = Data(#"{"id":"abc","name":"Sec","variables":[]}"#.utf8)
        let decoded = try JSONDecoder().decode(TestSuiteSection.self, from: json)
        #expect(decoded.expressions.isEmpty)
    }

    // MARK: - Manifest-level encoding

    @Test func testProperties_sectionExpressionsRoundTripThroughManifest() throws {
        let section = TestSuiteSection(
            id: "s1", name: "Q1",
            expressions: [PersonalizationExpression(name: "shift", expression: "seed % 13")]
        )
        let props = TestProperties(sections: [section])
        let data = try JSONEncoder().encode(props)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        #expect(decoded.sections.count == 1)
        #expect(decoded.sections[0].expressions.count == 1)
        #expect(decoded.sections[0].expressions[0].name == "shift")
    }

    @Test func testProperties_runnerSanitizedStripsSectionExpressions() {
        // Section expressions are a server-side authoring concern, exactly
        // like globalExpressions: their source is evaluated server-side per
        // student and only the resolved value travels to grading (via
        // Job.personalizedInputs / the browser seed endpoint).  The
        // runner-facing manifest must not carry the expression source (which
        // can be reference-solution code like `= solution.foo(...)`), so
        // runnerSanitized() strips them.  The section's literal *variables*
        // and its id/name are kept for parity with globalVariables.
        let section = TestSuiteSection(
            id: "s1", name: "Q1",
            variables: [FamilyVariable(name: "lo", value: .int(1))],
            expressions: [PersonalizationExpression(name: "x", expression: "seed % 2")]
        )
        let props = TestProperties(sections: [section])
        let sanitized = props.runnerSanitized()
        #expect(sanitized.sections.count == 1)
        #expect(sanitized.sections[0].id == "s1")
        #expect(sanitized.sections[0].variables.count == 1)
        #expect(
            sanitized.sections[0].expressions.isEmpty,
            "Section expressions are server-side only; the runner shouldn't see them.")
    }

    // MARK: - End-to-end evaluator integration

    @Test func evaluator_acceptsSectionExpressions() async throws {
        // The evaluator is kind-agnostic — section + global expressions
        // are concatenated and evaluated as one ordered list before
        // notebook substitution.  This test confirms a section
        // expression that references a global variable evaluates
        // correctly.
        let result = try await PersonalizationEvaluator.evaluate(
            seedHex: "0010",
            staticVariables: [
                FamilyVariable(
                    name: "quotes",
                    value: .array([.string("alpha"), .string("beta"), .string("gamma")]))
            ],
            expressions: [
                // Imagine this came from a section's expressions list.
                PersonalizationExpression(name: "pick", expression: "quotes[seed % len(quotes)]")
            ], language: .python
        )
        // seed = 0x0010 = 16; 16 % 3 = 1; quotes[1] = "beta".
        #expect(result["pick"] == "'beta'")
    }
}
