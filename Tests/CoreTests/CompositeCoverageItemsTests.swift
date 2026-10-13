// Tests/CoreTests/CompositeCoverageItemsTests.swift
//
// A class composite's slots are coverage items (docs/class-composite.md,
// slice 4): an unscoped `itemsCovered` class goal counts them, and a section
// scope does not.

import Core
import Testing

@Suite struct CompositeCoverageItemsTests {

    private func manifest(_ activity: ClassActivity?) -> TestProperties {
        TestProperties(
            testSuites: [TestSuiteEntry(tier: .pub, script: "tile.py", sectionID: "s1")],
            language: .python, activity: activity)
    }

    private let spec = CompositeSpec(
        compositor: .tile, layout: .grid(columns: 2, rows: 2),
        contribution: CompositeContributionShape(width: 4, height: 4, frames: 1, format: .gray8),
        dealOrder: .rowMajor)

    @Test func everySlotIsAnItemInSlotOrder() {
        #expect(spec.coverageItems == ["slot-0", "slot-1", "slot-2", "slot-3"])
        #expect(CompositeSpec.coverageItem(forSlot: 7) == "slot-7")
    }

    @Test func anUnscopedGoalCountsTheSlots() {
        let props = manifest(ClassActivity(kind: .classComposite, composite: spec))
        #expect(props.compositeCoverageItems == spec.coverageItems)
        #expect(props.coveredItemNames(inScopeOf: nil) == ["slot-0", "slot-1", "slot-2", "slot-3"])
    }

    @Test func aSectionScopeHasNoSlots() {
        let props = manifest(ClassActivity(kind: .classComposite, composite: spec))
        #expect(props.coveredItemNames(inScopeOf: AchievementTarget(kind: .section, ref: "s1")) == ["tile.py"])
    }

    @Test func anotherKindHasNoSlotItems() {
        let props = manifest(ClassActivity(kind: .bestMetric))
        #expect(props.compositeCoverageItems.isEmpty)
        #expect(props.coveredItemNames(inScopeOf: nil) == ["tile.py"])
    }
}
