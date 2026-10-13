// Tests/CoreTests/CompositeDealingTests.swift
//
// The deal order and the slot inputs of a class composite
// (docs/class-composite.md, slice 3).

import Core
import Testing

@Suite struct CompositeDealingTests {

    private func spec(
        _ compositor: CompositeCompositor = .tile, layout: CompositeLayout, order: CompositeDealOrder
    ) -> CompositeSpec {
        CompositeSpec(
            compositor: compositor, layout: layout,
            contribution: CompositeContributionShape(width: 4, height: 4, frames: 1, format: .gray8),
            dealOrder: order)
    }

    @Test func rowMajorDealsInSlotOrder() {
        let sequence = spec(layout: .grid(columns: 3, rows: 2), order: .rowMajor).dealSequence(shuffleSeed: 7)
        #expect(sequence == [0, 1, 2, 3, 4, 5])
    }

    /// An odd grid starts at its centre cell, then its four neighbours.
    @Test func centreOutStartsAtTheCentreOfAnOddGrid() {
        let sequence = spec(layout: .grid(columns: 3, rows: 3), order: .centreOut).dealSequence(shuffleSeed: 0)
        #expect(sequence.first == 4)
        #expect(Set(sequence.dropFirst().prefix(4)) == [1, 3, 5, 7])
        #expect(Set(sequence.suffix(4)) == [0, 2, 6, 8], "the corners come last")
    }

    /// In an even grid the centre falls between cells, so the four middle
    /// cells tie and come first, lowest slot first.
    @Test func centreOutStartsWithTheMiddleFourOfAnEvenGrid() {
        let sequence = spec(layout: .grid(columns: 4, rows: 4), order: .centreOut).dealSequence(shuffleSeed: 0)
        #expect(Array(sequence.prefix(4)) == [5, 6, 9, 10])
    }

    @Test func centreOutOnACountStartsInTheMiddle() {
        let sequence = spec(.sequence, layout: .count(5), order: .centreOut).dealSequence(shuffleSeed: 0)
        #expect(sequence == [2, 1, 3, 0, 4])
    }

    @Test(arguments: [CompositeDealOrder.rowMajor, .centreOut, .random])
    func everyOrderIsAPermutationOfTheSlots(order: CompositeDealOrder) {
        let sequence = spec(layout: .grid(columns: 8, rows: 6), order: order).dealSequence(shuffleSeed: 42)
        #expect(sequence.sorted() == Array(0..<48))
    }

    @Test func randomIsTheSameForOneSeedAndDiffersAcrossSeeds() {
        let random = spec(layout: .grid(columns: 8, rows: 6), order: .random)
        #expect(random.dealSequence(shuffleSeed: 1) == random.dealSequence(shuffleSeed: 1))
        #expect(random.dealSequence(shuffleSeed: 1) != random.dealSequence(shuffleSeed: 2))
        #expect(random.dealSequence(shuffleSeed: 1) != Array(0..<48), "a shuffle, not the identity")
    }

    @Test func aGridSlotCarriesItsColumnAndRow() {
        let inputs = spec(layout: .grid(columns: 8, rows: 6), order: .rowMajor).inputs(forSlot: 19)
        #expect(inputs[CompositeSpec.slotInputName] == .int(19))
        #expect(inputs[CompositeSpec.columnInputName] == .int(3))
        #expect(inputs[CompositeSpec.rowInputName] == .int(2))
    }

    @Test func aCountedSlotCarriesOnlyItsNumber() {
        let inputs = spec(.sum, layout: .count(36), order: .rowMajor).inputs(forSlot: 12)
        #expect(inputs == [CompositeSpec.slotInputName: .int(12)])
    }
}
