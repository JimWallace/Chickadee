// Tests/CoreTests/CompositeSpecTests.swift
//
// The `composite` block of a class-composite activity (docs/class-composite.md,
// slice 2): its JSON shape, its defaults, each save rule on its own, the
// structure the lock compares, and that every `ClassActivity` rebuild keeps it.

import Core
import Foundation
import Testing

@Suite struct CompositeSpecTests {

    private let tile = CompositeSpec(
        compositor: .tile, layout: .grid(columns: 8, rows: 6),
        contribution: CompositeContributionShape(width: 8, height: 8, frames: 1, format: .rgb8))

    private func spec(
        _ compositor: CompositeCompositor = .tile,
        layout: CompositeLayout = .grid(columns: 8, rows: 6),
        w: Int = 8, h: Int = 8, frames: Int = 1, format: CompositePixelFormat = .rgb8,
        frameRate: Int = 12, emptySlots: CompositeEmptySlots = .blank
    ) -> CompositeSpec {
        CompositeSpec(
            compositor: compositor, layout: layout,
            contribution: CompositeContributionShape(width: w, height: h, frames: frames, format: format),
            frameRate: frameRate, emptySlots: emptySlots)
    }

    // MARK: - The kind

    @Test func theKindHasNoOpponentAndTheCompositeAggregation() {
        #expect(ActivityKind.classComposite.opponentSource == .none)
        #expect(ActivityKind.classComposite.aggregation == .composite)
        #expect(!ClassActivity(kind: .classComposite).stagesAnOpponent)
        #expect(!ClassActivity(kind: .classComposite).takesAnOpponentFile)
    }

    // MARK: - Defaults and JSON

    @Test func theStarterIsValidAndUsesTheDocumentedDefaults() {
        let starter = CompositeSpec.starter
        #expect(starter.problem == nil)
        #expect(starter.layout.slotCount == 48)
        #expect(starter.dealOrder == .centreOut)
        #expect(starter.showFailed)
        #expect(starter.emptySlots == .blank)
    }

    @Test func theBlockRoundTripsWithTheDocumentedKeys() throws {
        let encoded = try JSONEncoder().encode(tile)
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let layout = try #require(object["layout"] as? [String: Any])
        let contribution = try #require(object["contribution"] as? [String: Any])
        #expect(Set(layout.keys) == ["cols", "rows"])
        #expect(Set(contribution.keys) == ["w", "h", "frames", "format"])
        #expect(try JSONDecoder().decode(CompositeSpec.self, from: encoded) == tile)

        let counted = spec(.sum, layout: .count(36))
        let countedObject = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(counted)) as? [String: Any])
        #expect(Set(try #require(countedObject["layout"] as? [String: Any]).keys) == ["count"])
    }

    /// The display settings are optional on the wire, as the rest of the
    /// activity block's fields are.
    @Test func absentDisplaySettingsDecodeToTheirDefaults() throws {
        let minimal = Data(
            #"{"compositor":"sequence","layout":{"count":24},"contribution":{"w":16,"h":16,"frames":1,"format":"gray8"}}"#
                .utf8)
        let decoded = try JSONDecoder().decode(CompositeSpec.self, from: minimal)
        #expect(decoded.layout == .count(24))
        #expect(decoded.dealOrder == .centreOut)
        #expect(decoded.frameRate == 12)
        #expect(decoded.showFailed)
        #expect(decoded.emptySlots == .blank)
    }

    /// An activity with no composite keeps the bytes it had before the field
    /// existed, so no stored manifest changes under this slice.
    @Test func anActivityWithoutACompositeEncodesNoCompositeKey() throws {
        let encoded = try JSONEncoder().encode(ClassActivity(kind: .bestMetric))
        let object = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["composite"] == nil)
    }

    @Test func aCompositeActivityRoundTrips() throws {
        let activity = ClassActivity(kind: .classComposite, composite: tile)
        let decoded = try JSONDecoder().decode(ClassActivity.self, from: JSONEncoder().encode(activity))
        #expect(decoded == activity)
    }

    // MARK: - Save rules

    @Test(arguments: [
        (CompositeCompositor.tile, CompositeLayout.count(4)),
        (.gallery, .count(4)),
        (.sequence, .grid(columns: 2, rows: 2)),
        (.sum, .grid(columns: 2, rows: 2)),
    ])
    func aLayoutOfTheWrongShapeIsRefused(compositor: CompositeCompositor, layout: CompositeLayout) {
        #expect(spec(compositor, layout: layout).problem == .layoutDoesNotFitCompositor(compositor))
    }

    @Test(arguments: [
        CompositeLayout.grid(columns: 0, rows: 4),
        .grid(columns: 33, rows: 1),
        .grid(columns: 1, rows: 33),
    ])
    func aGridOutOfRangeIsRefused(layout: CompositeLayout) {
        #expect(spec(.tile, layout: layout).problem == .slotCountOutOfRange)
    }

    @Test(arguments: [0, 257])
    func aCountOutOfRangeIsRefused(count: Int) {
        #expect(spec(.sequence, layout: .count(count)).problem == .slotCountOutOfRange)
    }

    @Test func theLargestGridAndCountAreAccepted() {
        #expect(spec(.tile, layout: .grid(columns: 16, rows: 16), w: 1, h: 1).problem == nil)
        #expect(spec(.sequence, layout: .count(256), w: 1, h: 1).problem == nil)
    }

    /// A 32 × 32 grid is 1024 slots, over the 256-slot limit, although each
    /// side is in range.
    @Test func aGridWithTooManySlotsIsRefused() {
        #expect(spec(.tile, layout: .grid(columns: 32, rows: 32), w: 1, h: 1).problem == .slotCountOutOfRange)
    }

    @Test(arguments: [
        (0, 8, 1), (8, 0, 1), (8, 8, 0), (257, 1, 1), (1, 1, 601),
        (256, 256, 1),  // 196,608 RGB bytes: over the 64 KB contribution cap
    ])
    func aContributionOutOfRangeIsRefused(w: Int, h: Int, frames: Int) {
        #expect(spec(w: w, h: h, frames: frames).problem == .contributionOutOfRange)
    }

    /// 256 slots of exactly 16 KB is the 4 MB limit; one more row of pixels
    /// in each contribution is over it.
    @Test func aTotalOverTheLimitIsRefused() {
        #expect(spec(.sequence, layout: .count(256), w: 128, h: 128, format: .gray8).problem == nil)
        #expect(
            spec(.sequence, layout: .count(256), w: 128, h: 129, format: .gray8).problem == .totalPayloadTooLarge)
    }

    @Test(arguments: [0, 61])
    func aFrameRateOutOfRangeIsRefused(rate: Int) {
        #expect(spec(frameRate: rate).problem == .frameRateOutOfRange)
    }

    @Test func referenceRendersAreRefusedForSumOnly() {
        #expect(spec(.sum, layout: .count(36), emptySlots: .reference).problem == .referenceNotForSum)
        #expect(spec(.sequence, layout: .count(36), emptySlots: .reference).problem == nil)
        #expect(spec(.tile, emptySlots: .reference).problem == nil)
    }

    @Test func everyProblemHasAMessage() {
        let problems: [CompositeSpecProblem] = [
            .layoutDoesNotFitCompositor(.tile), .layoutDoesNotFitCompositor(.sum), .slotCountOutOfRange,
            .contributionOutOfRange, .totalPayloadTooLarge, .frameRateOutOfRange, .referenceNotForSum,
        ]
        for problem in problems {
            #expect(!problem.message.isEmpty)
            #expect(!problem.message.contains("!"))
        }
    }

    // MARK: - The lock and reshaping

    @Test func structureCoversTheLockedFieldsOnly() {
        #expect(tile.hasSameStructure(as: tile.withDisplay(frameRate: 30, showFailed: false, emptySlots: .reference)))
        #expect(!tile.hasSameStructure(as: spec(layout: .grid(columns: 6, rows: 8))))
        #expect(!tile.hasSameStructure(as: spec(w: 16)))
        #expect(!tile.hasSameStructure(as: spec(.gallery)))
        let reordered = CompositeSpec(
            compositor: .tile, layout: tile.layout, contribution: tile.contribution, dealOrder: .random)
        #expect(!tile.hasSameStructure(as: reordered))
    }

    @Test func reshapingKeepsEverySlot() {
        #expect(CompositeLayout.grid(columns: 8, rows: 6).reshaped(forGrid: false) == .count(48))
        #expect(CompositeLayout.count(48).reshaped(forGrid: true) == .grid(columns: 7, rows: 7))
        #expect(CompositeLayout.count(36).reshaped(forGrid: true) == .grid(columns: 6, rows: 6))
        #expect(CompositeLayout.count(1).reshaped(forGrid: true) == .grid(columns: 1, rows: 1))
        #expect(CompositeLayout.count(5).reshaped(forGrid: false) == .count(5))
        for count in 1...CompositeSpec.maxSlots {
            #expect(CompositeLayout.count(count).reshaped(forGrid: true).slotCount >= count)
        }
    }

    // MARK: - Rebuilds

    /// Every `with…` rebuild keeps the composite, so saving one of the
    /// Activity section's other forms cannot drop it.
    @Test func eachRebuildKeepsTheComposite() {
        let activity = ClassActivity(kind: .classComposite, composite: tile)
        #expect(activity.withLeaderboardVisibility(.hidden).composite == tile)
        #expect(activity.withOpponentFile(nil).composite == tile)
        #expect(activity.withWindow(nil).composite == tile)
        #expect(activity.withComposite(nil).composite == nil)
        #expect(activity.withComposite(.starter).kind == .classComposite)
    }
}
