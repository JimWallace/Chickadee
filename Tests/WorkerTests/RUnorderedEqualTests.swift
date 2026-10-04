// Tests/WorkerTests/RUnorderedEqualTests.swift
//
// Executes `chickadee_unordered_equal` and `chickadee_equal` against the real
// R interpreter (#2016). The old unordered comparison flattened both sides with
// `unlist` and compared them as sorted strings, so it passed a number against a
// string, a nested list against a flat one, and two different sets of pairs —
// wrong answers awarded marks — while it failed two empty lists. It now
// compares the top-level elements with `chickadee_equal`, as Lua does. A JSON
// null renders as NA, so `chickadee_equal` also matches NA with NA; without
// that, the element-wise comparison would have failed every correct answer
// that contains a null.

import Foundation
import Testing

@testable import chickadee_runner

@Suite(.serialized, .timeLimit(.minutes(2))) struct RUnorderedEqualTests {

    /// Evaluates each R expression under the canonical runtime and returns
    /// what it printed, one `TRUE` or `FALSE` per expression.
    private func verdicts(_ expressions: [String]) async throws -> [String] {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ck-runordered-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        try testRuntimeSource(for: .r).write(
            to: dir.appendingPathComponent("test_runtime.R"), atomically: true, encoding: .utf8)
        let lines = expressions.map { "cat(isTRUE(\($0)), \"\\n\")" }
        let script = (["source(\"test_runtime.R\")"] + lines).joined(separator: "\n") + "\n"
        let scriptURL = dir.appendingPathComponent("probe.R")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)

        let run = try await runToolThrottled(["Rscript", scriptURL.path], workingDirectory: dir)
        #expect(run.exitCode == 0, "Rscript failed: \(run.stderr)")
        return run.stdout.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// The three wrong answers from the issue. Each one passed before.
    @Test(.requiresRscript) func wrongAnswersNoLongerPass() async throws {
        let result = try await verdicts([
            #"chickadee_unordered_equal(list(1), list("1"))"#,
            "chickadee_unordered_equal(list(list(1, 2), list(3, 4)), list(1, 2, 3, 4))",
            "chickadee_unordered_equal(list(list(1, 4), list(2, 3)), list(list(1, 2), list(3, 4)))",
        ])
        #expect(result == ["FALSE", "FALSE", "FALSE"])
    }

    /// What must still pass: a reordering, integer against double, a vector
    /// against a list, nested elements in another order, and a repeated element.
    @Test(.requiresRscript) func correctAnswersStillPass() async throws {
        let result = try await verdicts([
            "chickadee_unordered_equal(c(3, 1, 2), c(1, 2, 3))",
            "chickadee_unordered_equal(c(1L, 2L), c(2, 1))",
            #"chickadee_unordered_equal(c("b", "a"), list("a", "b"))"#,
            "chickadee_unordered_equal(list(list(3, 4), list(1, 2)), list(list(1, 2), list(3, 4)))",
            "chickadee_unordered_equal(c(1, 1, 2), c(2, 1, 1))",
            "chickadee_unordered_equal(list(), list())",
        ])
        #expect(result == ["TRUE", "TRUE", "TRUE", "TRUE", "TRUE", "TRUE"])
    }

    /// The element-wise comparison is still a multiset, not a set.
    @Test(.requiresRscript) func countsAndLengthsStillMatter() async throws {
        let result = try await verdicts([
            "chickadee_unordered_equal(c(1, 1, 2), c(1, 2, 2))",
            "chickadee_unordered_equal(c(1, 2, 3), c(1, 2))",
            "chickadee_unordered_equal(function() 1, list())",
        ])
        #expect(result == ["FALSE", "FALSE", "FALSE"])
    }

    /// A JSON null renders as NA. It matches NA in either comparison, and only NA.
    @Test(.requiresRscript) func aNullMatchesOnlyANull() async throws {
        let result = try await verdicts([
            "chickadee_equal(NA, NA)",
            "chickadee_equal(c(1, NA, 3), c(1, NA, 3))",
            "chickadee_unordered_equal(c(3, NA, 1), c(1, NA, 3))",
            "chickadee_equal(c(1, NA), c(1, 2))",
            #"chickadee_equal("a", NA)"#,
            "chickadee_unordered_equal(c(3, NA), c(3, 1))",
        ])
        #expect(result == ["TRUE", "TRUE", "TRUE", "FALSE", "FALSE", "FALSE"])
    }
}
