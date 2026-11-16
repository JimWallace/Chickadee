// Tests/APITests/Courses/CourseTermInputTests.swift
//
// The parse of a course form's year and term fields (docs/course-terms.md):
// a form that posts neither field is `absent`, and a form that posts only one
// of them is `invalid`. A steward mutation run (2026-11-16) found that no
// suite told the two apart.

import Core
import Testing

@testable import APIServer

@Suite struct CourseTermInputTests {

    @Test func neitherFieldPostedIsAbsent() {
        #expect(CourseTermInput(year: nil, season: nil) == .absent)
    }

    @Test(arguments: [
        (String?.some("2026"), String?.none),
        (String?.none, String?.some("fall")),
    ])
    func oneFieldPostedIsInvalid(year: String?, season: String?) {
        #expect(CourseTermInput(year: year, season: season) == .invalid)
    }

    @Test func bothFieldsPostedBlankAreInvalid() {
        #expect(CourseTermInput(year: "", season: "") == .invalid)
        #expect(CourseTermInput(year: "  ", season: "\n") == .invalid)
    }

    @Test func bothFieldsPostedMakeATerm() throws {
        let expected = try #require(AcademicTerm(year: 2026, season: .fall))
        #expect(CourseTermInput(year: " 2026 ", season: "fall\n") == .term(expected))
    }

    @Test(arguments: [
        ("26", "fall"),
        ("20260", "fall"),
        ("twenty", "fall"),
        ("2026", "autumn"),
        ("2026", "Fall"),
    ])
    func aYearOrSeasonThatIsNotATermIsInvalid(year: String, season: String) {
        #expect(CourseTermInput(year: year, season: season) == .invalid)
    }
}
