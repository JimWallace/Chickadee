// Tests/CoreTests/EvalWorkerLanguageTableTests.swift
//
// Every in-page auto-compute language names `/eval-worker.js?lang=<language>`
// (#2721), and `Public/eval-worker.js` holds one entry for each `lang`. The
// two halves are in two languages, so nothing but this test connects them.
//
// A descriptor whose `lang` has no entry makes the worker refuse to start, and
// auto-compute stops with no message in the editor. An entry that no
// descriptor names is dead code that looks supported.

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@Suite struct EvalWorkerLanguageTableTests {

    /// The `lang` keys of the worker's `_EVALUATORS` table: the lines that open
    /// an entry at the table's own indent, `    <lang>: {`. Comment lines are
    /// skipped, so prose that names a language cannot count as an entry.
    private func workerLanguages() throws -> Set<String> {
        let url = repositoryRoot.appendingPathComponent("Public/eval-worker.js")
        let source = try String(contentsOf: url, encoding: .utf8)
        let entry = /^    ([a-z]+): \{$/
        var keys: Set<String> = []
        for line in source.split(separator: "\n", omittingEmptySubsequences: false) {
            if let match = line.wholeMatch(of: entry) { keys.insert(String(match.1)) }
        }
        return keys
    }

    /// The languages whose descriptor computes in the page.
    private var inPageLanguages: Set<String> {
        Set(
            AssignmentLanguage.allCases.compactMap { language in
                guard case .inPageKernel = language.descriptor.autoCompute else { return nil }
                return language.rawValue
            })
    }

    @Test func theWorkerHasAnEntryForEveryInPageLanguageAndNoOther() throws {
        let keys = try workerLanguages()
        #expect(!keys.isEmpty, "the scanner found no entry, so it no longer reads the table")
        #expect(keys == inPageLanguages)
    }
}
