// Tests/APITests/CollectionGradeFieldsTests.swift
//
// The grade fields of a collection blob, decoded once (#1931). The decoder
// must keep the old per-field reading: a field that is missing or of the
// wrong type is nil, and the other fields keep their values.

import Testing

@testable import APIServer

@Suite struct CollectionGradeFieldsTests {

    @Test func aBlobDecodesAllFourFieldsAndIgnoresTheRest() throws {
        let fields = try #require(
            CollectionGradeFields(
                json: #"{"earnedPoints":2.75,"totalPoints":4,"passCount":3,"totalTests":4,"outcomes":[]}"#))
        #expect(
            fields
                == CollectionGradeFields(earnedPoints: 2.75, totalPoints: 4, passCount: 3, totalTests: 4))
    }

    /// The old reader cast each field on its own, so one bad field did not
    /// hide the others. A whole-struct decode would have dropped all four.
    @Test func aFieldOfTheWrongTypeIsNilAndTheOthersSurvive() throws {
        let fields = try #require(
            CollectionGradeFields(json: #"{"earnedPoints":"7","totalPoints":8,"passCount":3,"totalTests":4}"#))
        #expect(fields.earnedPoints == nil)
        #expect(fields.totalPoints == 8)
        #expect(fields.passCount == 3)
        #expect(fields.totalTests == 4)
    }

    @Test func aCountWrittenAsAWholeDoubleStillReads() throws {
        let fields = try #require(CollectionGradeFields(json: #"{"passCount":3.0,"totalTests":4.0}"#))
        #expect(fields.passCount == 3)
        #expect(fields.totalTests == 4)
        #expect(fields.gradePercent == 75)
    }

    @Test func aFractionalCountIsNotACount() throws {
        let fields = try #require(CollectionGradeFields(json: #"{"passCount":2.5,"totalTests":4}"#))
        #expect(fields.passCount == nil)
        #expect(fields.gradePercent == nil)
    }

    @Test(arguments: ["not-json", "[1,2]", "42", ""])
    func aBlobThatIsNotAnObjectDecodesToNil(json: String) {
        #expect(CollectionGradeFields(json: json) == nil)
    }

    @Test func anEmptyObjectHasNoGrade() throws {
        let fields = try #require(CollectionGradeFields(json: "{}"))
        #expect(fields.gradePercent == nil)
        #expect(fields.gradePoints == nil)
        #expect(fields.gradeTotalPoints == nil)
    }

    @Test func zeroTotalPointsFallsBackToTheCounts() {
        let fields = CollectionGradeFields(earnedPoints: 0, totalPoints: 0, passCount: 1, totalTests: 2)
        #expect(fields.gradePercent == 50)
        #expect(fields.gradePoints == 1)
        #expect(fields.gradeTotalPoints == nil)
    }

    /// The column accessors on APIResult and the blob readers now share one
    /// set of formulas. A result stamped from a blob reports what the blob
    /// reports.
    @Test(arguments: [
        #"{"earnedPoints":7,"totalPoints":8,"passCount":1,"totalTests":4}"#,
        #"{"earnedPoints":2.75,"totalPoints":4,"passCount":3,"totalTests":4}"#,
        #"{"passCount":3,"totalTests":4}"#,
        #"{"earnedPoints":0,"totalPoints":0,"passCount":0,"totalTests":0}"#,
    ])
    func aStampedResultAgreesWithItsBlob(json: String) {
        let result = APIResult(id: "r", submissionID: "s")
        result.stampGradeFields(from: json)
        #expect(result.gradePercentValue == gradePercentFromCollectionJSON(json))
        #expect(result.gradePointsValue == gradePointsFromCollectionJSON(json))
        #expect(result.gradeTotalPointsValue == gradeTotalPointsFromCollectionJSON(json))
    }

    @Test func stampingFromABlobThatIsNotAnObjectLeavesTheColumnsAlone() {
        let result = APIResult(id: "r", submissionID: "s")
        result.passCount = 2
        result.totalTests = 3
        result.stampGradeFields(from: "not-json")
        #expect(result.passCount == 2)
        #expect(result.totalTests == 3)
    }
}
