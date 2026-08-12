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
// TWO deliberate gaps, both the same shape: a name that is REFERENCED by a
// Python-shaped parser elsewhere cannot be widened on its own, because the
// result is not a refusal but a silent misread.
//
//   * Global and section INPUT names — referenced from starter notebooks as
//     `{{name}}`, parsed by `NotebookSubstitution.placeholderRegex`, which
//     hardcodes `[A-Za-z_][A-Za-z0-9_]*`. Widening the check alone lets an
//     author save `bmi-value` and leaves `{{bmi-value}}` as literal text in
//     every student's notebook.
//   * Family `variables` — referenced from an arg cell as `$name`, parsed by
//     the same shape in `pattern-family-editor.js`. Widening the check alone
//     makes `$bmi-value` fall through as a literal STRING, i.e. a wrong
//     expected value in a generated test, reported nowhere.
//
// `paramNames` and `.variableEquality`'s case variable have no such referencing
// parser — they are rendered directly into generated source — which is exactly
// why those two are widened here and the other two are not.
//
// Separately: the web editor's own `isValidServerIdentifier` is still Python's
// grammar, so until it learns the language, these names are reachable through
// MCP and REST but refused client-side in the browser. That is a narrowing bug
// in the UI, not a correctness one in the save path.

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

    // MARK: - Family-scoped variables stay on Python's grammar, ON PURPOSE

    /// A plain name still works everywhere.
    @Test(arguments: AssignmentLanguage.allCases)
    func familyVariableAcceptsAPlainNameInEveryLanguage(language: AssignmentLanguage) throws {
        try validate(
            family(
                function: validTarget(for: language),
                variables: [FamilyVariable(name: "threshold_value", value: .double(25))]),
            language)
    }

    /// But an R or Racket spelling is REFUSED even on its own language — the
    /// one place this change deliberately stops short.
    ///
    /// A family variable is referenced from an arg cell as `$name`, and the web
    /// editor parses that with `/^\$([A-Za-z_][A-Za-z0-9_]*)$/`. Accepting
    /// `threshold-value` here would make `$threshold-value` match nothing and
    /// fall through as a literal string — a wrong expected value in a generated
    /// test, reported nowhere. Widening the server alone converts a clear
    /// refusal into a silent miscompare, which is strictly worse.
    ///
    /// When the editor's `$name` parser learns the language's grammar, delete
    /// this test and fold these names into the accepting one above.
    @Test(
        arguments: [
            ("threshold.value", AssignmentLanguage.r),
            ("threshold-value", AssignmentLanguage.racket),
        ])
    func familyVariableRefusesANonPythonSpellingPendingTheRefParser(
        name: String, language: AssignmentLanguage
    ) {
        #expect(throws: (any Error).self) {
            try validate(
                family(
                    function: validTarget(for: language),
                    variables: [FamilyVariable(name: name, value: .double(25))]),
                language)
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
