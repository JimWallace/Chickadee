// Regression guard for the SIBLINGS of the language-blind `functionName` check.
//
// #1341 made a family's `functionName` language-aware and stopped there. The
// same file went on validating three other author-supplied names against
// Python's rules on every assignment:
//
//   * `paramNames` — a family's parameter list.
//   * `variables` — family-scoped literals referenced from arg cells.
//   * `.variableEquality`'s per-case variable name — a module-level name in
//     the student's own submission.
//
// So a Racket author could finally save `bmi-category` as the target and was
// then refused on the parameter `bmi-value`, with a message naming Python. The
// fix points all three at `isValidIdentifier(_:language:)` — which already
// existed, `private`, in `NotebookCheckKindHandler.swift`, written for notebook
// checks and never shared. Nothing was missing; it was out of reach.
//
// These assert the OUTCOME an author sees, not that a particular predicate ran
// — the predicate was being called correctly the whole time it was wrong.
//
// NOTE the deliberate gap: global and section INPUT names are still held to
// Python's grammar, and that is not an oversight. They are referenced from
// starter notebooks as `{{name}}`, and `NotebookSubstitution.placeholderRegex`
// hardcodes `[A-Za-z_][A-Za-z0-9_]*`. Widening the name check alone would let
// an author save `bmi-value` and then silently leave `{{bmi-value}}` as literal
// text in every student's notebook. The two must move together.

import Core
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct PatternFamilyIdentifierGrammarTests {

    private func family(
        function: String = "f",
        paramNames: [String] = ["x"],
        variables: [FamilyVariable] = []
    ) -> PatternFamily {
        PatternFamily(
            id: "fam",
            name: "Family",
            kind: .boundaryEquality,
            functionName: function,
            paramNames: paramNames,
            cases: [
                PatternCase(
                    key: "01", label: "A case",
                    args: [.double(1)], expected: .string("ok"))
            ],
            variables: variables
        )
    }

    private func validate(_ f: PatternFamily, _ language: AssignmentLanguage) throws {
        try validatePatternFamilies([f], testSuites: [], language: language)
    }

    /// A call target that language accepts, so a test about PARAMETER names is
    /// not failed by the `functionName` check standing in front of it. Java is
    /// the one that matters: its target must be qualified, so the bare `f`
    /// every other language takes is refused there.
    private func validTarget(for language: AssignmentLanguage) -> String {
        language == .java ? "Solution.f" : "f"
    }

    // MARK: - Parameter names

    /// The parameter spellings each language's authors actually write. Every
    /// one must save; the last two are what #1341 left broken.
    @Test(
        arguments: [
            ("bmi_value", AssignmentLanguage.python),
            ("bmi.value", AssignmentLanguage.r),
            ("bmiValue", AssignmentLanguage.java),
            ("bmi-value", AssignmentLanguage.racket),
        ])
    func parameterNameAcceptedInItsOwnLanguage(name: String, language: AssignmentLanguage) throws {
        try validate(
            family(function: validTarget(for: language), paramNames: [name]), language)
    }

    /// An R name is still refused on a Python assignment — widening the grammar
    /// per language must not widen it everywhere.
    @Test func parameterNameRefusedInAForeignLanguage() {
        #expect(throws: (any Error).self) {
            try validate(family(paramNames: ["bmi-value"]), .python)
        }
    }

    /// The refusal names the assignment's language, not Python. This is the
    /// half an author actually reads, and naming Python on a Racket assignment
    /// is what made the original defect unactionable.
    @Test func parameterRefusalNamesTheAssignmentsLanguage() throws {
        do {
            try validate(family(paramNames: ["has space"]), .racket)
            Issue.record("expected a refusal for an invalid Racket parameter name")
        } catch let error as Abort {
            #expect(error.reason.contains("Racket"))
            #expect(!error.reason.contains("Python"))
        }
    }

    // MARK: - Family-scoped variables

    @Test(
        arguments: [
            ("threshold_value", AssignmentLanguage.python),
            ("threshold.value", AssignmentLanguage.r),
            ("threshold-value", AssignmentLanguage.racket),
        ])
    func familyVariableAcceptedInItsOwnLanguage(name: String, language: AssignmentLanguage) throws {
        try validate(family(variables: [FamilyVariable(name: name, value: .double(25))]), language)
    }

    @Test func familyVariableRefusedInAForeignLanguage() {
        #expect(throws: (any Error).self) {
            try validate(
                family(variables: [FamilyVariable(name: "threshold-value", value: .double(25))]),
                .python)
        }
    }

    // MARK: - variableEquality's per-case variable name

    /// This one names a variable in the STUDENT'S submission, so Python's rules
    /// were refusing authors the right to test an idiomatic name in their own
    /// language.
    @Test(
        arguments: [
            ("total_count", AssignmentLanguage.python),
            ("total.count", AssignmentLanguage.r),
            ("total-count", AssignmentLanguage.racket),
        ])
    func variableEqualityNameAcceptedInItsOwnLanguage(
        name: String, language: AssignmentLanguage
    ) throws {
        let f = PatternFamily(
            id: "vars",
            name: "Module variables",
            kind: .variableEquality,
            functionName: "",
            paramNames: [],
            cases: [
                PatternCase(
                    key: "01", label: "The count",
                    args: [.string(name)], expected: .double(3))
            ]
        )
        try validate(f, language)
    }
}
