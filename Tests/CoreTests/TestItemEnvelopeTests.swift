// Tests/CoreTests/TestItemEnvelopeTests.swift
//
// The shared envelope accessors of `TestItem` (`displayName`, `dependsOn`)
// for both flavours, and two small instructor-facing labels in Core:
// `AssignmentType.withArticle` and `ProgramIOComparison.displayName`.

import Core
import Foundation
import Testing

@Suite struct TestItemEnvelopeTests {

    @Test func aFamilyExposesItsNameAndPrerequisites() {
        let item = TestItem.family(
            PatternFamily(
                id: "bmi", name: "BMI classes", kind: .boundaryEquality, functionName: "classify_bmi",
                dependsOn: ["test_load.py", "family:setup"]))
        #expect(item.displayName == "BMI classes")
        #expect(item.dependsOn == ["test_load.py", "family:setup"])
    }

    @Test func aCheckExposesItsOptionalNameAndPrerequisites() {
        let named = TestItem.check(
            NotebookCheck(id: "shape", name: "Data frame shape", kind: .dataFrameShape, dependsOn: ["test_a.py"]))
        #expect(named.displayName == "Data frame shape")
        #expect(named.dependsOn == ["test_a.py"])

        let unnamed = TestItem.check(NotebookCheck(id: "fn", kind: .functionExists, variable: "mean_rate"))
        #expect(unnamed.displayName == nil)
        #expect(unnamed.dependsOn.isEmpty)
    }

    @Test func eachAssignmentTypeHasItsIndefiniteArticle() {
        #expect(AssignmentType.assignment.withArticle == "an Assignment")
        #expect(AssignmentType.lab.withArticle == "a Lab")
        #expect(AssignmentType.classActivity.withArticle == "a Class activity")
    }

    /// The article form ends with the display name, so the two cannot drift.
    @Test(arguments: [AssignmentType.assignment, .lab, .classActivity])
    func theArticleFormEndsWithTheDisplayName(_ type: AssignmentType) {
        #expect(type.withArticle.hasSuffix(" " + type.displayName))
    }

    @Test func eachProgramIOComparisonHasALabel() {
        #expect(ProgramIOComparison.exact.displayName == "Exact match")
        #expect(ProgramIOComparison.included.displayName == "Contains")
        #expect(ProgramIOComparison.regex.displayName == "Matches regex")
        #expect(Set(ProgramIOComparison.allCases.map(\.displayName)).count == ProgramIOComparison.allCases.count)
    }
}
