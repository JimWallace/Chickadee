// Tests/CoreTests/LineDiffTests.swift

import Testing

@testable import Core

@Suite struct LineDiffTests {

    @Test func identicalInputsAreAllContext() {
        let rows = LineDiff.unified(old: ["a", "b"], new: ["a", "b"], context: nil)
        #expect(rows.map(\.kind) == [.context, .context])
        #expect(rows.map(\.oldNumber) == [1, 2])
        #expect(rows.map(\.newNumber) == [1, 2])
    }

    @Test func insertionsAndRemovalsCarryOneSidedNumbers() {
        let rows = LineDiff.unified(old: ["a", "b", "c"], new: ["a", "x", "c", "d"], context: nil)
        #expect(rows.map(\.kind) == [.context, .removed, .added, .context, .added])
        #expect(rows[1].oldNumber == 2 && rows[1].newNumber == nil && rows[1].text == "b")
        #expect(rows[2].oldNumber == nil && rows[2].newNumber == 2 && rows[2].text == "x")
        #expect(rows[4].newNumber == 4 && rows[4].text == "d")
        let counts = LineDiff.counts(rows)
        #expect(counts.added == 2 && counts.removed == 1)
    }

    @Test func longUnchangedRunsFoldAroundContext() {
        let old = (1...20).map { "line \($0)" }
        var new = old
        new[10] = "changed"
        let rows = LineDiff.unified(old: old, new: new, context: 2)
        // Head run of 10 folds to a fold + 2 trailing context lines; tail run
        // of 9 folds to 2 leading context lines + a fold.
        #expect(rows.map(\.kind) == [.fold, .context, .context, .removed, .added, .context, .context, .fold])
        #expect(rows[0].text == "8 unchanged lines")
        #expect(rows[0].oldNumber == 1)
        #expect(rows[7].text == "7 unchanged lines")
        #expect(rows[7].oldNumber == 14)
    }

    @Test func shortRunsAreNotFolded() {
        let rows = LineDiff.unified(old: ["a", "b", "c"], new: ["a", "b", "c", "d"], context: 3)
        #expect(!rows.contains { $0.kind == .fold })
    }

    @Test func emptyOldSideIsAllAdded() {
        let rows = LineDiff.unified(old: [], new: ["a", "b"], context: 3)
        #expect(rows.map(\.kind) == [.added, .added])
    }
}
