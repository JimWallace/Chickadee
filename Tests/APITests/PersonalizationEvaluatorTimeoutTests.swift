// Tests/APITests/PersonalizationEvaluatorTimeoutTests.swift
//
// The evaluator's per-language subprocess limit (#2001). The limit also covers
// the interpreter's start-up and, for C++ and Java, a compile, so the
// languages that compile or start slowly get a longer one. An explicit
// `timeoutSeconds` still wins.

import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct PersonalizationEvaluatorTimeoutTests {

    /// C++ and Java compile on every evaluation, and Racket expands a support
    /// helper from source on every evaluation. Measured on an idle host, each
    /// takes 1.5 to 3.5 s with one helper, so 5 s is not enough under load.
    @Test(arguments: [AssignmentLanguage.cpp, .java, .racket])
    func aLanguageThatCompilesGetsTheLongerLimit(language: AssignmentLanguage) {
        #expect(PersonalizationEvaluator.defaultTimeoutSeconds(for: language) == 15)
    }

    @Test(arguments: [AssignmentLanguage.python, .r, .lua, .octave])
    func aLanguageThatStartsQuicklyKeepsFiveSeconds(language: AssignmentLanguage) {
        #expect(PersonalizationEvaluator.defaultTimeoutSeconds(for: language) == 5)
    }

    /// No language's limit is below the original 5 s.
    @Test func noLanguageGetsLessThanTheOriginalLimit() {
        for language in AssignmentLanguage.allCases {
            #expect(PersonalizationEvaluator.defaultTimeoutSeconds(for: language) >= 5)
        }
    }

    /// A caller that passes a limit gets that limit, not the language's.
    @Test func anExplicitLimitStillWins() async throws {
        let slow = PersonalizationExpression(name: "v", expression: "__import__('time').sleep(3) or 1")
        await #expect {
            _ = try await PersonalizationEvaluator.evaluate(
                seedHex: "ff", staticVariables: [], expressions: [slow], language: .python,
                timeoutSeconds: 1)
        } throws: { error in
            if case PersonalizationEvaluatorError.timedOut = error { return true }
            return false
        }
    }
}
