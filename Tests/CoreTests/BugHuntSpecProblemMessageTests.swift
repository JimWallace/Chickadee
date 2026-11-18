// Tests/CoreTests/BugHuntSpecProblemMessageTests.swift
//
// The message each `BugHuntSpecProblem` shows the author. `BugHuntSpecTests`
// pins which problem a block reports; this suite pins the text, which is
// what the author reads when the save is refused.

import Core
import Foundation
import Testing

@Suite struct BugHuntSpecProblemMessageTests {

    @Test func everyProblemHasItsOwnMessage() {
        let cases: [(BugHuntSpecProblem, String)] = [
            (.noItems, "A bug hunt needs at least one item: the suite entries the class covers together."),
            (.duplicateItem("bug_01.py"), "The item \"bug_01.py\" is listed twice."),
            (.regionsWithoutCode, "Regions need the code they point into. Add the code, or remove the regions."),
            (.codeWithoutRegions, "The code map needs at least one region that ties an item to its lines."),
            (.unreadableLines("7-x"), "\"7-x\" is not a line or a range of lines. Write \"7\" or \"12-18\"."),
            (.linesOutsideCode("40-50"), "The lines \"40-50\" fall outside the code."),
            (
                .regionItemNotListed("bug_09.py"),
                "The region for \"bug_09.py\" names an item that is not in the item list."
            ),
        ]
        for (problem, message) in cases {
            #expect(problem.message == message)
        }
    }

    /// The size message reads its numbers from the limits, so a change to a
    /// limit changes the message with it.
    @Test func theSizeMessageNamesTheLimits() {
        let message = BugHuntSpecProblem.codeTooLarge.message
        #expect(message == "The code map shows at most 400 lines and 32 KB of code.")
        #expect(message.contains("\(BugHuntSpec.maxCodeLines) lines"))
        #expect(message.contains("\(BugHuntSpec.maxCodeBytes / 1024) KB"))
    }

    /// The message of the problem a real block reports, end to end.
    @Test func aBlockWithTooManyLinesReportsTheSizeMessage() throws {
        let code = Array(repeating: "x = 1", count: BugHuntSpec.maxCodeLines + 1).joined(separator: "\n")
        let spec = BugHuntSpec(
            items: ["a.py"], code: code, regions: [BugHuntRegion(item: "a.py", lines: "1")])
        let problem = try #require(spec.problem)
        #expect(problem == .codeTooLarge)
        #expect(problem.message.hasPrefix("The code map shows at most"))
    }
}
