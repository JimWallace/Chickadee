// Tests/CoreTests/AcademicTermTests.swift
//
// `AcademicTerm` is the year + Waterloo term of one course offering
// (docs/course-terms.md). These tests pin the four-digit year rule, the
// calendar order of the seasons, and the rule that half a stored term
// resolves to no term at all.

import Foundation
import Testing

@testable import Core

@Suite struct AcademicTermTests {

    @Test func seasonsAreInCalendarOrder() {
        #expect(TermSeason.allCases == [.winter, .spring, .fall])
        #expect(TermSeason.allCases.map(\.displayName) == ["Winter", "Spring", "Fall"])
        #expect(TermSeason.allCases.map(\.startMonth) == [1, 5, 9])
    }

    @Test(arguments: [999, 10000, 0, -2026])
    func yearMustHaveFourDigits(year: Int) {
        #expect(AcademicTerm(year: year, season: .fall) == nil)
    }

    @Test(arguments: [1000, 2026, 9999])
    func fourDigitYearsAreAccepted(year: Int) throws {
        let term = try #require(AcademicTerm(year: year, season: .winter))
        #expect(term.year == year)
    }

    @Test func displayNameIsSeasonThenYear() throws {
        let term = try #require(AcademicTerm(year: 2026, season: .fall))
        #expect(term.displayName == "Fall 2026")
    }

    @Test func resolveNeedsBothHalves() throws {
        #expect(AcademicTerm.resolve(year: nil, season: nil) == nil)
        #expect(AcademicTerm.resolve(year: 2026, season: nil) == nil)
        #expect(AcademicTerm.resolve(year: nil, season: "fall") == nil)
        #expect(AcademicTerm.resolve(year: 2026, season: "autumn") == nil)
        #expect(AcademicTerm.resolve(year: 26, season: "fall") == nil)
        let term = try #require(AcademicTerm.resolve(year: 2026, season: "spring"))
        #expect(term.season == .spring)
    }

    @Test func termsOrderChronologically() throws {
        let winter26 = try #require(AcademicTerm(year: 2026, season: .winter))
        let spring26 = try #require(AcademicTerm(year: 2026, season: .spring))
        let fall26 = try #require(AcademicTerm(year: 2026, season: .fall))
        let winter27 = try #require(AcademicTerm(year: 2027, season: .winter))
        #expect([fall26, winter27, winter26, spring26].sorted() == [winter26, spring26, fall26, winter27])
        #expect(!(fall26 < spring26))
    }

    @Test func nextAdvancesThroughTheYear() throws {
        let winter26 = try #require(AcademicTerm(year: 2026, season: .winter))
        #expect(winter26.next?.displayName == "Spring 2026")
        #expect(winter26.next?.next?.displayName == "Fall 2026")
        #expect(winter26.next?.next?.next?.displayName == "Winter 2027")
        #expect(AcademicTerm(year: 9999, season: .fall)?.next == nil)
    }

    @Test func codableRoundTripsAndRejectsABadYear() throws {
        let term = try #require(AcademicTerm(year: 2027, season: .winter))
        let data = try JSONEncoder().encode(term)
        #expect(try JSONDecoder().decode(AcademicTerm.self, from: data) == term)

        let bad = Data(#"{"year": 27, "season": "winter"}"#.utf8)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(AcademicTerm.self, from: bad)
        }
    }
}

@Suite struct AcademicTermLabelTests {

    @Test(arguments: [
        (2026, TermSeason.fall, "F26"), (2027, .winter, "W27"), (2005, .spring, "S05"), (2100, .fall, "F00"),
    ])
    func shortLabelIsInitialAndTwoDigitYear(year: Int, season: TermSeason, label: String) throws {
        let term = try #require(AcademicTerm(year: year, season: season))
        #expect(term.shortLabel == label)
    }

    @Test func ordinalStepsByOnePerTerm() throws {
        let fall26 = try #require(AcademicTerm(year: 2026, season: .fall))
        let winter27 = try #require(fall26.next)
        let spring27 = try #require(winter27.next)
        #expect(winter27.ordinal == fall26.ordinal + 1)
        #expect(spring27.ordinal == winter27.ordinal + 1)
    }
}
