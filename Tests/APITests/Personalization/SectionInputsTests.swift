// Tests/APITests/Personalization/SectionInputsTests.swift
//
// Slice 4 of issue #461 — section variables can carry per-student
// expressions (parity with Slice 2's global expressions).  These tests
// focus on the schema + evaluator-integration surface; the JS
// classification logic mirrors `Public/global-inputs-editor.js` and
// is covered by the global-inputs unit tests in spirit.
//
// `SectionInputsServiceValidationTests` covers the refusals in
// `SectionInputsService` that the MCP tool suite
// (`UpdateSectionVariablesToolTests`) does not reach: the expression-row name
// checks, a clash with another section, a manifest that is not JSON, and the
// save-time evaluation (a variable of another section in scope, a raising
// expression, a timeout, an evaluator failure). A refused save must leave the
// section's persisted inputs as they were. Each test asserts the error case
// and the words the author reads, not only that the line ran.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct SectionInputsTests {

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
        let props = TestProperties(language: nil, sections: [section])
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
        let props = TestProperties(language: nil, sections: [section])
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

// MARK: - Service validation

@Suite(.serialized, .timeLimit(.minutes(3))) struct SectionInputsServiceValidationTests {

    // MARK: - Helpers

    /// The `unprocessable` reason that `body` throws, or nil when it throws
    /// nothing. Any other error fails the test.
    private func unprocessableReason(_ body: () async throws -> Void) async throws -> String? {
        do {
            try await body()
            return nil
        } catch AppError.unprocessable(let reason) {
            return reason
        }
    }

    private func expression(_ name: String, _ body: String) -> PersonalizationExpression {
        PersonalizationExpression(name: name, expression: body)
    }

    private func validate(_ expressions: [PersonalizationExpression]) throws {
        _ = try SectionInputsService.validateNames(variables: [], expressions: expressions, language: .python)
    }

    // MARK: - validateNames (pure)

    @Test func anExpressionNameThatIsNotAnIdentifierIsRefused() async throws {
        let reason = try await unprocessableReason { try validate([expression("2fast", "seed")]) }
        #expect(reason?.hasPrefix("Section expression name '2fast' is not valid here") == true)
    }

    @Test func anExpressionCannotTakeTheReservedSeedName() async throws {
        let reason = try await unprocessableReason { try validate([expression("seed", "1")]) }
        #expect(reason == "'seed' is reserved for Chickadee's personalization seed.")
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func anExpressionWithAnEmptyBodyIsRefused(_ body: String) async throws {
        let reason = try await unprocessableReason { try validate([expression("shift", body)]) }
        #expect(reason?.hasPrefix("Section expression 'shift' has an empty body.") == true)
    }

    @Test func anExpressionThatRepeatsALiteralNameIsRefused() async throws {
        let reason = try await unprocessableReason {
            _ = try SectionInputsService.validateNames(
                variables: [FamilyVariable(name: "x", value: .int(1))], expressions: [expression("x", "seed")],
                language: .python)
        }
        #expect(reason?.hasPrefix("Duplicate section input name 'x'.") == true)
        #expect(reason?.contains("unique across literal values and expressions") == true)
    }

    @Test func distinctValidNamesAreAllReturned() throws {
        let names = try SectionInputsService.validateNames(
            variables: [FamilyVariable(name: "lo", value: .int(1))],
            expressions: [expression("hi", "lo + seed % 5")], language: .python)
        #expect(names == ["lo", "hi"])
    }

    // MARK: - validateAgainstOtherScopes (pure)

    @Test func aNameThatAnotherSectionUsesIsRefused() async throws {
        let manifest = TestProperties(
            language: .python,
            sections: [
                TestSuiteSection(id: "s1", name: "Q1"),
                TestSuiteSection(id: "s2", name: "Q2", expressions: [expression("n", "seed")]),
            ])
        let reason = try await unprocessableReason {
            try SectionInputsService.validateAgainstOtherScopes(seenNames: ["n"], manifest: manifest, sectionID: "s1")
        }
        #expect(reason?.hasPrefix("Section input 'n' is already used by a global input or another section.") == true)
    }

    /// The section's own earlier names are not a clash: a save replaces them.
    @Test func theSectionsOwnNamesAreNotAClash() throws {
        let manifest = TestProperties(
            language: .python,
            sections: [TestSuiteSection(id: "s1", name: "Q1", variables: [FamilyVariable(name: "n", value: .int(3))])])
        try SectionInputsService.validateAgainstOtherScopes(seenNames: ["n"], manifest: manifest, sectionID: "s1")
    }

    // MARK: - Manifest decode

    @Test func currentRefusesAManifestThatIsNotJSON() throws {
        let setup = APITestSetup(id: "sis_bad", manifest: "{not json", zipPath: "/nonexistent.zip", courseID: UUID())
        #expect {
            _ = try SectionInputsService.current(setup: setup, sectionID: "s1")
        } throws: { error in
            guard case AppError.internalFailure(let reason) = error else { return false }
            return reason == "Manifest is not valid JSON."
        }
    }

    @Test func applyRefusesAManifestThatIsNotJSON() async throws {
        try await withTestApp { app in
            let setup = APITestSetup(
                id: "sis_bad_apply", manifest: "{not json", zipPath: "/nonexistent.zip", courseID: UUID())
            await #expect {
                try await SectionInputsService.apply(
                    setup: setup, sectionID: "s1", inputs: .init(variables: [], expressions: []),
                    seed: .init(
                        actingUserID: nil, assignmentID: nil, testSetupID: "sis_bad_apply",
                        testSetupsDirectory: app.testSetupsDirectory),
                    on: app.db, seedDB: app.db)
            } throws: { error in
                guard case AppError.internalFailure(let reason) = error else { return false }
                return reason == "Manifest is not valid JSON."
            }
        }
    }

    // MARK: - Save-time evaluation (Python driver, database for the seed)

    /// Two sections: `s1` is the one saved, `s2` carries the literal `lo = 7`.
    private let twoSections = TestProperties(
        language: .python,
        sections: [
            TestSuiteSection(id: "s1", name: "Q1"),
            TestSuiteSection(id: "s2", name: "Q2", variables: [FamilyVariable(name: "lo", value: .int(7))]),
        ])

    /// Saves `expressions` into section `s1` through `apply`, as the acting
    /// instructor, and returns the inputs that `s1` holds afterwards.
    private func save(
        _ expressions: [PersonalizationExpression], in app: Application
    ) async throws -> SectionInputsService.Inputs? {
        let scenario = try await TestScenario.make(
            on: app, setupID: "sis_eval", properties: twoSections, withNotebook: false)
        let userID = try await scenario.enroll("sis_author", role: "instructor", on: app)
        let seed = SectionInputsService.SeedContext(
            actingUserID: userID, assignmentID: scenario.assignmentID, testSetupID: scenario.setupID,
            testSetupsDirectory: app.testSetupsDirectory)
        do {
            try await SectionInputsService.apply(
                setup: scenario.setup, sectionID: "s1", inputs: .init(variables: [], expressions: expressions),
                seed: seed, on: app.db, seedDB: app.db)
        } catch {
            // The refused save must not have touched the stored manifest.
            let stored = try #require(try await APITestSetup.find(scenario.setupID, on: app.db))
            let inputs = try SectionInputsService.current(setup: stored, sectionID: "s1")
            #expect(inputs?.expressions.isEmpty == true, "a refused save persists nothing")
            throw error
        }
        let stored = try #require(try await APITestSetup.find(scenario.setupID, on: app.db))
        return try SectionInputsService.current(setup: stored, sectionID: "s1")
    }

    /// A variable of another section is in scope for this section's
    /// expression at save time, as it is when a student first opens the
    /// notebook. The saved expression is persisted on the section.
    @Test(.requiresPython3) func anExpressionMayReadAnotherSectionsVariable() async throws {
        try await withTestApp { app in
            let inputs = try await save([expression("hi", "lo + 1")], in: app)
            #expect(inputs?.expressions == [expression("hi", "lo + 1")])
        }
    }

    @Test(.requiresPython3) func aRaisingExpressionNamesTheFailure() async throws {
        try await withTestApp { app in
            let reason = try await unprocessableReason {
                _ = try await save([expression("boom", "1 / 0")], in: app)
            }
            let text = try #require(reason)
            #expect(text.hasPrefix("One of your section expressions failed to evaluate:"))
            #expect(text.contains("ZeroDivisionError"))
            #expect(text.hasSuffix("Fix the expression(s) and save again."))
        }
    }

    @Test(.requiresPython3) func aSlowExpressionTimesOut() async throws {
        let limit = PersonalizationEvaluator.defaultTimeoutSeconds(for: .python)
        try await withTestApp { app in
            let reason = try await unprocessableReason {
                _ = try await save([expression("slow", "__import__('time').sleep(\(limit * 4))")], in: app)
            }
            #expect(reason?.hasPrefix("Expression evaluation timed out (>\(limit)s).") == true)
        }
    }

    /// A driver that exits 0 without its JSON line is not the author's syntax
    /// error, so it is an internal failure, not a validation refusal.
    @Test(.requiresPython3) func aDriverWithNoOutputIsAnInternalFailure() async throws {
        try await withTestApp { app in
            await #expect {
                _ = try await save([expression("quiet", "__import__('os')._exit(0)")], in: app)
            } throws: { error in
                guard case AppError.internalFailure(let reason) = error else { return false }
                return reason.hasPrefix("Expression evaluator failed:")
            }
        }
    }
}
