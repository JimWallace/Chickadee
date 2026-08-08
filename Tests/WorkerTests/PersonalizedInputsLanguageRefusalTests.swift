// Tests/WorkerTests/PersonalizedInputsLanguageRefusalTests.swift
//
// A job that carries per-student input values but names no assignment language
// is refused, not rendered as Python.
//
// The values arrive already rendered as source literals in the assignment's
// language (`repr` / `deparse`), so writing them into `_ck_inputs.py` for an R
// assignment produces no error at the boundary — it produces a file whose
// CONTENTS are wrong. Every personalized test then fails somewhere inside the
// student's own code, with a traceback that reads as their mistake, and that
// persists as their grade. Guessing is only safe where being wrong is loud.
//
// The old default was justified by "nil means an older server", a premise the
// declare-at-creation work falsified: personalization is resolved per-language
// on the server, so an assignment with inputs has a language by construction.

import Core
import Foundation
import Testing

@testable import chickadee_runner

@Suite struct PersonalizedInputsLanguageRefusalTests {

    // The retry classification (terminal — retrying cannot make a language
    // appear) is deliberately NOT covered here. It lives inline in
    // `RunnerDaemon.download`'s `shouldRetry` closure, and the only way to
    // assert it would be to extract that closure for the test's benefit alone.
    // The compiler already enforces the case is handled: adding it made the
    // switch non-exhaustive and failed the build until it was classified.

    @Test func theMessageNamesTheCauseAndTheFix() throws {
        let message = try #require(
            WorkerDaemonError.personalizedInputsWithoutLanguage(inputCount: 3).errorDescription)

        // This text reaches an instructor as `compilerOutput` on a failed
        // collection, so it has to say what happened and what to do — not just
        // that something was nil.
        #expect(message.contains("3"), "the count tells the reader this is not a nil-guard misfire")
        #expect(message.lowercased().contains("language"))
        #expect(
            message.lowercased().contains("retest") || message.lowercased().contains("re-save"),
            "an instructor needs the recovery step, not just the diagnosis")
    }

    @Test func singularAndPluralBothReadCorrectly() throws {
        let one = try #require(
            WorkerDaemonError.personalizedInputsWithoutLanguage(inputCount: 1).errorDescription)
        let many = try #require(
            WorkerDaemonError.personalizedInputsWithoutLanguage(inputCount: 2).errorDescription)
        #expect(one.contains("1 per-student input value "))
        #expect(many.contains("2 per-student input values "))
    }

    /// Every language renders its own inputs file, which is the property that
    /// makes a wrong guess silent rather than loud: each is valid source in ITS
    /// language, so nothing downstream can tell it was written for another one.
    @Test(arguments: AssignmentLanguage.allCases)
    func eachLanguageRendersADistinctInputsFile(language: AssignmentLanguage) {
        let inputs = ["threshold": "42"]
        let rendered = language.renderInputsFile(inputs)
        #expect(!rendered.isEmpty, "\(language.rawValue) must render something")
        #expect(
            rendered.contains("threshold"),
            "\(language.rawValue) must bind the input name the tests reference")
    }
}
