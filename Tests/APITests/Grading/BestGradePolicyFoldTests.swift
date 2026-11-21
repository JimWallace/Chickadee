// Tests/APITests/Grading/BestGradePolicyFoldTests.swift
//
// #1111 — the "highest grade wins" policy is one pure fold shared by every
// grade-displaying surface. This suite pins the fold itself;
// `StudentDrilldownGradeTests` pins the drilldown page that used to
// disagree with it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct BestGradePolicyFoldTests {

    private func result(
        id: String, submissionID: String = "sub", source: String, pass: Int, total: Int
    ) -> APIResult {
        let result = APIResult(id: id, submissionID: submissionID, source: source)
        result.stampGradeFields(from: #"{"passCount": \#(pass), "totalTests": \#(total)}"#)
        return result
    }

    @Test func bestGradePercentTakesMaxAcrossSources() {
        let rows = [
            result(id: "r1", source: "browser", pass: 5, total: 5),
            result(id: "r2", source: "worker", pass: 4, total: 5),
        ]
        #expect(bestGradePercent(of: rows) == 100)
        #expect(bestGradePercent(of: rows.reversed()) == 100)
    }

    @Test func bestGradePercentNilWhenNoParseableGrade() {
        let noGrade = APIResult(id: "r0", submissionID: "sub", source: "worker")
        #expect(bestGradePercent(of: [noGrade]) == nil)
        #expect(bestGradePercent(of: [APIResult]()) == nil)
    }

    @Test func bestGradeResultReturnsWinningRow() {
        let rows = [
            result(id: "r1", source: "worker", pass: 3, total: 5),
            result(id: "r2", source: "browser", pass: 5, total: 5),
            result(id: "r3", source: "worker", pass: 4, total: 5),
        ]
        #expect(bestGradeResult(of: rows)?.id == "r2")
        let noGrade = APIResult(id: "r0", submissionID: "sub", source: "worker")
        #expect(bestGradeResult(of: [noGrade]) == nil)
    }
}
