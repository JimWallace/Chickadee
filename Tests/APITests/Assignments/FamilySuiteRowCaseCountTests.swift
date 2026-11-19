// Tests/APITests/Assignments/FamilySuiteRowCaseCountTests.swift
//
// `FamilySuiteRow` is one pattern family's row in the suite editor. Its
// `caseCountText` is the row subtitle, and its hand-written `encode(to:)`
// must emit that computed property, which synthesized coding would skip.

import Foundation
import Testing

@testable import APIServer

@Suite struct FamilySuiteRowCaseCountTests {

    private static func row(caseCount: Int) -> FamilySuiteRow {
        FamilySuiteRow(
            id: "fam1", name: "Mean", functionName: "mean", tier: "public",
            caseCount: caseCount, totalPoints: caseCount * 2)
    }

    @Test(arguments: [(0, "0 cases"), (1, "1 case"), (2, "2 cases"), (12, "12 cases")])
    func caseCountTextPluralises(count: Int, expected: String) {
        #expect(Self.row(caseCount: count).caseCountText == expected)
    }

    @Test func encodingCarriesTheCaseCountText() throws {
        let data = try JSONEncoder().encode(Self.row(caseCount: 3))
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["caseCountText"] as? String == "3 cases")
        #expect(object["id"] as? String == "fam1")
        #expect(object["name"] as? String == "Mean")
        #expect(object["functionName"] as? String == "mean")
        #expect(object["tier"] as? String == "public")
        #expect(object["caseCount"] as? Int == 3)
        #expect(object["totalPoints"] as? Int == 6)
        #expect(object.count == 7)
    }
}
