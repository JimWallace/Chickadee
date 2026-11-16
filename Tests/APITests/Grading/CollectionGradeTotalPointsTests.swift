// Tests/APITests/Grading/CollectionGradeTotalPointsTests.swift
//
// `CollectionGradeFields.gradeTotalPoints`: the total possible points, read
// only when the run was weighted (`totalPoints` above zero). A steward
// mutation run (2026-11-16) found that no suite read it for a weighted run,
// so turning `totalPoints > 0` into `totalPoints < 0` went unseen. The cases
// belong with `CollectionGradeFieldsTests`; they are in a new file because the
// unattended steward does not edit an existing test file.

import Testing

@testable import APIServer

@Suite struct CollectionGradeTotalPointsTests {

    @Test func aWeightedRunReportsItsTotal() {
        let fields = CollectionGradeFields(earnedPoints: 6, totalPoints: 8, passCount: 3, totalTests: 4)
        #expect(fields.gradeTotalPoints == 8)
        #expect(fields.gradePoints == 6)
        #expect(fields.gradePercent == 75)
    }

    @Test func aNegativeTotalIsNotATotal() {
        let fields = CollectionGradeFields(earnedPoints: 1, totalPoints: -4, passCount: 1, totalTests: 2)
        #expect(fields.gradeTotalPoints == nil)
        #expect(fields.gradePoints == 1)
        #expect(fields.gradePercent == 50)
    }

    @Test func aMissingTotalIsNotATotal() {
        let fields = CollectionGradeFields(earnedPoints: 3, totalPoints: nil, passCount: 3, totalTests: 4)
        #expect(fields.gradeTotalPoints == nil)
    }
}
