// Tests/APITests/Assignments/AssignmentTypeRulesProseTests.swift
//
// Pins the sentences `AssignmentTypeRules` builds for each type, and the Type
// select's marked option. `AssignmentTypeRulesTests.everyTypeStatesItsRules`
// checks only the count and that MCP reports the same list, so a sentence
// that states the opposite rule passed it (mutation run, 2026-11-18).

import Core
import Testing

@testable import APIServer

@Suite struct AssignmentTypeRulesProseTests {

    @Test func anAssignmentStatesTheWorkerRules() {
        #expect(
            AssignmentTypeRules.rules(for: .assignment) == [
                "Graded by the native worker by default.",
                "Browser grading is refused, because it would deliver the release and secret tests to "
                    + "every student.",
                "Grades go to the LMS (BrightSpace or LTI).",
                "Students may spend slip days.",
            ])
    }

    @Test func aLabStatesTheBrowserRules() {
        #expect(
            AssignmentTypeRules.rules(for: .lab) == [
                "Graded in the student browser by default.",
                "Browser grading is allowed, where the language and the activity allow it.",
                "Grades go to the LMS (BrightSpace or LTI).",
                "Students may spend slip days.",
            ])
    }

    @Test func aClassActivityStatesItsActivityAndKeepsItsGrades() {
        #expect(
            AssignmentTypeRules.rules(for: .classActivity) == [
                "Graded by the native worker by default.",
                "Browser grading is allowed, where the language and the activity allow it.",
                "Requires an activity block.",
                "Grades stay in Chickadee for the leaderboard and achievements, and are not sent to the "
                    + "LMS.",
                "Slip days do not apply.",
            ])
    }

    @Test(arguments: AssignmentType.allCases)
    func theSelectMarksOnlyTheSelectedType(type: AssignmentType) {
        let options = AssignmentTypeRules.options(selected: type)
        #expect(options.map(\.value) == AssignmentType.allCases.map(\.rawValue))
        #expect(options.filter(\.selected).map(\.value) == [type.rawValue])
    }

    @Test func noSelectedTypeMarksNoOption() {
        #expect(AssignmentTypeRules.options(selected: nil).allSatisfy { !$0.selected })
    }
}
