// Tests/APITests/Personalization/GlobalInputsServiceValidationTests.swift
//
// The refusals in `GlobalInputsService` that the MCP tool suite
// (`UpdateGlobalInputsToolTests`) does not reach: the expression-row name
// checks, a clash with a section variable, an undeclared starter-notebook
// placeholder, the save-time evaluation failures (a raising expression, a
// timeout, an evaluator failure) and a manifest that is not JSON. Each test
// asserts the error case and the words the author reads, not only that the
// line ran.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) struct GlobalInputsServiceValidationTests {

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

    // MARK: - validateNames (pure)

    @Test func aRepeatedLiteralNameIsRefused() async throws {
        let reason = try await unprocessableReason {
            _ = try GlobalInputsService.validateNames(
                variables: [FamilyVariable(name: "k", value: .int(1)), FamilyVariable(name: "k", value: .int(2))],
                expressions: [], language: .python)
        }
        #expect(reason == "Duplicate global input name 'k'.")
    }

    @Test func anExpressionNameThatIsNotAnIdentifierIsRefused() async throws {
        let reason = try await unprocessableReason {
            _ = try GlobalInputsService.validateNames(
                variables: [], expressions: [expression("2fast", "seed")], language: .python)
        }
        #expect(reason?.hasPrefix("Global expression name '2fast' is not valid here") == true)
    }

    @Test func anExpressionCannotTakeTheReservedSeedName() async throws {
        let reason = try await unprocessableReason {
            _ = try GlobalInputsService.validateNames(
                variables: [], expressions: [expression("seed", "1")], language: .python)
        }
        #expect(reason?.contains("reserved for Chickadee's personalization seed") == true)
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func anExpressionWithAnEmptyBodyIsRefused(_ body: String) async throws {
        let reason = try await unprocessableReason {
            _ = try GlobalInputsService.validateNames(
                variables: [], expressions: [expression("shift", body)], language: .python)
        }
        #expect(reason?.hasPrefix("Global expression 'shift' has an empty body.") == true)
    }

    @Test func twoExpressionsWithOneNameAreRefused() async throws {
        let reason = try await unprocessableReason {
            _ = try GlobalInputsService.validateNames(
                variables: [], expressions: [expression("x", "seed"), expression("x", "seed + 1")],
                language: .python)
        }
        #expect(reason?.hasPrefix("Duplicate global input name 'x'.") == true)
        #expect(reason?.contains("unique across literal values and expressions") == true)
    }

    @Test func distinctValidNamesAreAllReturned() throws {
        let names = try GlobalInputsService.validateNames(
            variables: [FamilyVariable(name: "lo", value: .int(1))],
            expressions: [expression("hi", "lo + seed % 5")], language: .python)
        #expect(names == ["lo", "hi"])
    }

    // MARK: - validateAgainstSections (pure)

    @Test func aGlobalNameThatASectionUsesIsRefused() async throws {
        let manifest = TestProperties(
            language: .python,
            sections: [
                TestSuiteSection(id: "s1", name: "Question 1", variables: [FamilyVariable(name: "n", value: .int(3))])
            ])
        let reason = try await unprocessableReason {
            try GlobalInputsService.validateAgainstSections(seenNames: ["n"], manifest: manifest)
        }
        #expect(reason?.hasPrefix("Global input name 'n' is already used by section 'Question 1'.") == true)
    }

    @Test func namesThatNoSectionUsesPass() throws {
        let manifest = TestProperties(
            language: .python,
            sections: [TestSuiteSection(id: "s1", name: "Q1", variables: [FamilyVariable(name: "n", value: .int(3))])])
        try GlobalInputsService.validateAgainstSections(seenNames: ["m"], manifest: manifest)
    }

    // MARK: - Starter-notebook placeholders (needs the zip tools)

    @Test(.requiresZipTools) func anUndeclaredStarterPlaceholderIsRefused() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gis-placeholder-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let zipPath = directory.appendingPathComponent("setup.zip").path
        let notebook = """
            {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
            {"cell_type":"code","source":["x = {{declared}} + {{missing}}"],"metadata":{},"outputs":[],"execution_count":null}]}
            """
        try await writeZipFixture(at: zipPath, entries: [("starter.ipynb", notebook)])
        let setup = APITestSetup(id: "gis_starter", manifest: "{}", zipPath: zipPath, courseID: UUID())
        let manifest = TestProperties(starterNotebook: "starter.ipynb", language: .python)

        let reason = try await unprocessableReason {
            try await GlobalInputsService.validateStarterNotebookPlaceholders(
                seenNames: ["declared"], manifest: manifest, setup: setup)
        }
        #expect(reason?.hasPrefix("Starter notebook references unknown placeholder(s): {{missing}}.") == true)

        // Declaring the second name clears the refusal.
        try await GlobalInputsService.validateStarterNotebookPlaceholders(
            seenNames: ["declared", "missing"], manifest: manifest, setup: setup)
    }

    // MARK: - Manifest decode

    @Test func currentRefusesAManifestThatIsNotJSON() throws {
        let setup = APITestSetup(id: "gis_bad", manifest: "{not json", zipPath: "/nonexistent.zip", courseID: UUID())
        #expect {
            _ = try GlobalInputsService.current(setup: setup)
        } throws: { error in
            guard case AppError.internalFailure(let reason) = error else { return false }
            return reason == "Manifest is not valid JSON."
        }
    }

    // MARK: - Save-time evaluation (Python driver, database for the seed)

    private func evaluate(
        _ expressions: [PersonalizationExpression], sections: [TestSuiteSection] = []
    ) async throws {
        try await withTestApp { app in
            let scenario = try await TestScenario.make(
                on: app, setupID: "gis_eval", manifest: TestManifests.pythonDeclaredEmpty, withNotebook: false)
            let userID = try await scenario.enroll("gis_author", role: "instructor", on: app)
            try await GlobalInputsService.evaluateForActingSeed(
                actingUserID: userID,
                assignment: scenario.assignment,
                manifest: TestProperties(language: .python, sections: sections),
                inputs: .init(variables: [], expressions: expressions),
                testSetupsDirectory: app.testSetupsDirectory,
                seedDB: app.db)
        }
    }

    /// A section variable is in scope for a global expression at save time,
    /// as it is when a student first opens the notebook.
    @Test(.requiresPython3) func anExpressionMayReadASectionVariable() async throws {
        try await evaluate(
            [expression("hi", "lo + 1")],
            sections: [TestSuiteSection(id: "s1", name: "Q1", variables: [FamilyVariable(name: "lo", value: .int(7))])])
    }

    @Test(.requiresPython3) func aRaisingExpressionNamesTheFailure() async throws {
        let reason = try await unprocessableReason {
            try await evaluate([expression("boom", "1 / 0")])
        }
        let text = try #require(reason)
        #expect(text.hasPrefix("One of your expressions failed to evaluate:"))
        #expect(text.contains("ZeroDivisionError"))
        #expect(text.hasSuffix("Fix the expression(s) and save again."))
    }

    @Test(.requiresPython3) func aSlowExpressionTimesOut() async throws {
        let limit = PersonalizationEvaluator.defaultTimeoutSeconds(for: .python)
        let reason = try await unprocessableReason {
            try await evaluate([expression("slow", "__import__('time').sleep(\(limit * 4))")])
        }
        #expect(reason?.hasPrefix("Expression evaluation timed out (>\(limit)s).") == true)
    }

    /// A driver that exits 0 without its JSON line is not the author's syntax
    /// error, so it is an internal failure, not a validation refusal.
    @Test(.requiresPython3) func aDriverWithNoOutputIsAnInternalFailure() async throws {
        await #expect {
            try await evaluate([expression("quiet", "__import__('os')._exit(0)")])
        } throws: { error in
            guard case AppError.internalFailure(let reason) = error else { return false }
            return reason.hasPrefix("Expression evaluator failed:")
        }
    }
}
