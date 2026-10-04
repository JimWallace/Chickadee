// Tests/CoreTests/GradePercentTests.swift
//
// The whole-number grade percent (#2018): rounded to the nearest whole number,
// but only a full mark reads 100.

import Core
import Testing

@Suite struct GradePercentTests {

    @Test func anImperfectScoreNeverReads100() {
        #expect(GradePercent.of(earned: 199, total: 200) == 99)
        #expect(GradePercent.of(earned: 99.5, total: 100) == 99)
        #expect(GradePercent.of(earned: 999, total: 1000) == 99)
    }

    @Test func aFullMarkReads100() {
        #expect(GradePercent.of(earned: 200, total: 200) == 100)
        #expect(GradePercent.of(earned: 7, total: 7) == 100)
    }

    /// Points are sums of fractional scores, so a full mark can land a
    /// rounding error below the total. It still reads 100.
    @Test func aFullMarkSummedFromFractionsReads100() {
        let earned = (0..<10).reduce(0.0) { sum, _ in sum + 0.1 }
        #expect(earned < 1)
        #expect(GradePercent.of(earned: earned, total: 1) == 100)
    }

    @Test func everyOtherScoreRoundsToTheNearestPercent() {
        #expect(GradePercent.of(earned: 1, total: 3) == 33)
        #expect(GradePercent.of(earned: 2, total: 3) == 67)
        #expect(GradePercent.of(earned: 99.4, total: 100) == 99)
        #expect(GradePercent.of(earned: 0, total: 5) == 0)
    }

    /// A class-goal bonus can lift the earned points past the total.
    @Test func aScoreAboveTheTotalIsAFullMark() {
        #expect(GradePercent.of(earned: 210, total: 200) == 105)
    }

    @Test func noTotalHasNoPercent() {
        #expect(GradePercent.of(earned: 0, total: 0) == nil)
        #expect(GradePercent.of(earned: 3, total: -1) == nil)
    }
}
