// Tests/CoreTests/LineDiffTrailingRemovalTests.swift
//
// Lines removed from the END of the old side, after the new side has run out.
// `LineDiffTests` covers an empty old side and removals in the middle, but
// never old lines outliving new ones, so the mutation sweep of 2026-09-22
// (#1574) turned the walk's `oldIndex < old.count` into `>` and nothing
// failed: the walk then stopped as soon as the new side was exhausted and the
// diff silently dropped every trailing removal.

import Testing

@testable import Core

@Suite struct LineDiffTrailingRemovalTests {

    @Test func removalsAfterTheNewSideEndsAreListed() {
        let rows = LineDiff.unified(old: ["a", "b", "c"], new: ["a"], context: nil)
        #expect(rows.map(\.kind) == [.context, .removed, .removed])
        #expect(rows.map(\.text) == ["a", "b", "c"])
        #expect(rows.map(\.oldNumber) == [1, 2, 3])
        #expect(LineDiff.counts(rows).removed == 2)
    }

    @Test func anEmptyNewSideIsAllRemoved() {
        let rows = LineDiff.unified(old: ["a", "b"], new: [], context: 3)
        #expect(rows.map(\.kind) == [.removed, .removed])
        #expect(rows.map(\.newNumber) == [nil, nil])
    }
}
