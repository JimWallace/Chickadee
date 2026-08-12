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
// The names that are REFERENCED elsewhere — family variables via `$name`, and
// global/section inputs via `{{name}}` — are now checked per language too.
//
// They could not be while the reference PARSERS carried their own copy of a
// grammar: both matched `[A-Za-z_][A-Za-z0-9_]*`, so a name an author could
// legally declare on an R or Racket assignment was unreferenceable, and failed
// as a SILENT MISREAD rather than a refusal (`$bmi-value` falling through as a
// literal string; `{{my.df}}` surviving into a student's notebook as text).
//
// The fix was not to teach those parsers the grammar — Racket's is a negative
// rule that no character class expresses — but to stop them having one. A
// parser grabs a token; deciding whether the token is a legal name belongs to
// the validator, which already answers per language and is exhaustive over all
// seven. Once the duplication went, the subset had nothing left to protect.
//
// The editor's own check went permissive rather than learning the grammar, for
// the same reason: the server answers per language, so any fixed rule in the
// browser is a second copy that can only drift from it.

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

    /// A plain name still works everywhere.
    @Test(arguments: AssignmentLanguage.allCases)
    func familyVariableAcceptsAPlainNameInEveryLanguage(language: AssignmentLanguage) throws {
        try validate(
            family(
                function: validTarget(for: language),
                variables: [FamilyVariable(name: "threshold_value", value: .double(25))]),
            language)
    }

    /// And each language's own spelling is accepted too, now that the editor's
    /// `$name` parser is a permissive token grab rather than a second copy of
    /// the grammar. While those two duplicated each other, this had to stay on
    /// the cross-language subset: `$threshold-value` matched nothing and fell
    /// through as a literal string, which is a wrong expected value in a
    /// generated test rather than a refusal.
    @Test(
        arguments: [
            ("threshold.value", AssignmentLanguage.r),
            ("threshold-value", AssignmentLanguage.racket),
        ])
    func familyVariableAcceptsItsOwnLanguagesSpelling(
        name: String, language: AssignmentLanguage
    ) throws {
        try validate(
            family(
                function: validTarget(for: language),
                variables: [FamilyVariable(name: name, value: .double(25))]),
            language)
    }

    /// A reserved word is still refused, in the language that reserves it —
    /// which the cross-language subset could not do. An input named `template`
    /// on a C++ assignment used to pass (Python has no such keyword) and then
    /// render `inline const auto template = …`, which does not compile.
    @Test(
        arguments: [
            ("template", AssignmentLanguage.cpp),
            ("class", AssignmentLanguage.java),
            ("function", AssignmentLanguage.lua),
        ])
    func familyVariableRefusesAReservedWordInItsOwnLanguage(
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
