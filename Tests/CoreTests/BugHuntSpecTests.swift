// Tests/CoreTests/BugHuntSpecTests.swift
//
// The `bugHunt` block (docs/bug-hunt-code-map.md): the save rules, the line
// ranges, each line's state, and the bytes it writes.

import Core
import Foundation
import Testing

@Suite struct BugHuntSpecTests {
    private let code = "def f(x):\n    if x < 0:\n        return 0\n    return x\n"

    @Test func aListOfItemsAloneIsValid() {
        #expect(BugHuntSpec(items: ["bug_01.py", "bug_02.py"]).problem == nil)
    }

    @Test func eachRuleIsReported() {
        #expect(BugHuntSpec(items: []).problem == .noItems)
        #expect(BugHuntSpec(items: ["a.py", "a.py"]).problem == .duplicateItem("a.py"))
        #expect(
            BugHuntSpec(items: ["a.py"], regions: [BugHuntRegion(item: "a.py", lines: "1")]).problem
                == .regionsWithoutCode)
        #expect(BugHuntSpec(items: ["a.py"], code: code).problem == .codeWithoutRegions)
        #expect(
            BugHuntSpec(items: ["a.py"], code: code, regions: [BugHuntRegion(item: "a.py", lines: "3-2")]).problem
                == .unreadableLines("3-2"))
        #expect(
            BugHuntSpec(items: ["a.py"], code: code, regions: [BugHuntRegion(item: "a.py", lines: "4-5")]).problem
                == .linesOutsideCode("4-5"))
        #expect(
            BugHuntSpec(items: ["a.py"], code: code, regions: [BugHuntRegion(item: "b.py", lines: "2")]).problem
                == .regionItemNotListed("b.py"))
        let huge = String(repeating: "x\n", count: BugHuntSpec.maxCodeLines + 1)
        #expect(
            BugHuntSpec(items: ["a.py"], code: huge, regions: [BugHuntRegion(item: "a.py", lines: "1")]).problem
                == .codeTooLarge)
    }

    @Test(arguments: [("7", 7...7), ("12-18", 12...18), (" 3 - 4 ", 3...4)])
    func aRangeReads(lines: String, expected: ClosedRange<Int>) {
        #expect(BugHuntRegion(item: "a.py", lines: lines).lineRange == expected)
    }

    @Test(arguments: ["", "0", "a", "1-", "-2", "1-2-3"])
    func aMalformedRangeDoesNotRead(lines: String) {
        #expect(BugHuntRegion(item: "a.py", lines: lines).lineRange == nil)
    }

    /// A line is dark until covered, partial while only some of the items on
    /// it are covered, and lit once all are. A line outside every region stays
    /// plain. The trailing newline adds no line.
    @Test func eachLineTakesTheStateOfItsRegions() {
        let spec = BugHuntSpec(
            items: ["a.py", "b.py"], code: code,
            regions: [BugHuntRegion(item: "a.py", lines: "2-3"), BugHuntRegion(item: "b.py", lines: "3")])
        #expect(spec.codeLines.count == 4)
        #expect(spec.problem == nil)
        #expect(spec.lineStates(covered: []) == [.plain, .dark, .dark, .plain])
        #expect(spec.lineStates(covered: ["a.py"]) == [.plain, .lit, .partial, .plain])
        #expect(spec.lineStates(covered: ["a.py", "b.py"]) == [.plain, .lit, .lit, .plain])
    }

    /// A block with no code writes no code and no regions, and an empty code
    /// string reads as no code.
    @Test func theBlockWritesOnlyWhatItHas() throws {
        let data = try JSONEncoder().encode(BugHuntSpec(items: ["a.py"], code: ""))
        let json = try #require(String(data: data, encoding: .utf8))
        #expect(json == #"{"items":["a.py"]}"#)
        let decoded = try JSONDecoder().decode(BugHuntSpec.self, from: data)
        #expect(decoded == BugHuntSpec(items: ["a.py"]))
        #expect(!decoded.showsCode)
    }

    /// The kind ranks nobody and stages nothing.
    @Test func theKindIsACoverageBoardWithNoOpponent() {
        #expect(ActivityKind.bugHunt.aggregation == .coverage)
        #expect(ActivityKind.bugHunt.opponentSource == .none)
        #expect(!ActivityKind.bugHunt.comparesStudents)
        #expect(!ActivityKind.bugHunt.canRunPerGroup)
    }

    /// The block travels in the activity block and comes back unchanged.
    @Test func theActivityBlockCarriesIt() throws {
        let spec = BugHuntSpec(
            items: ["a.py"], code: code, regions: [BugHuntRegion(item: "a.py", lines: "2")])
        let activity = ClassActivity(kind: .bugHunt, bugHunt: spec)
        let decoded = try JSONDecoder().decode(ClassActivity.self, from: JSONEncoder().encode(activity))
        #expect(decoded.bugHunt == spec)
        #expect(decoded.withWindow(LiveSessionWindow(closesAtISO: "2027-01-30T15:00:00Z")).bugHunt == spec)
    }
}
