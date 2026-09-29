// Tests/CoreTests/BundledCourseTermTests.swift
//
// A course bundle carries the offering's year and term
// (docs/course-terms.md slice 2). An older bundle, or half a term, resolves
// to no term rather than a guess.

import Foundation
import Testing

@testable import Core

@Suite struct BundledCourseTermTests {

    @Test func termRoundTripsThroughABundle() throws {
        let term = try #require(AcademicTerm(year: 2026, season: .fall))
        let course = BundledCourse(code: "CS135", name: "Intro", term: term)
        let data = try JSONEncoder().encode(course)
        let decoded = try JSONDecoder().decode(BundledCourse.self, from: data)
        #expect(decoded.termYear == 2026)
        #expect(decoded.termSeason == "fall")
        #expect(bundledCourseTerm(decoded) == term)
    }

    @Test func legacyBundleHasNoTerm() throws {
        let json = #"{ "code": "CS135", "name": "Intro" }"#
        let decoded = try JSONDecoder().decode(BundledCourse.self, from: Data(json.utf8))
        #expect(bundledCourseTerm(decoded) == nil)
    }

    @Test func halfATermInABundleIsNoTerm() throws {
        let json = #"{ "code": "CS135", "name": "Intro", "termYear": 2026 }"#
        let decoded = try JSONDecoder().decode(BundledCourse.self, from: Data(json.utf8))
        #expect(bundledCourseTerm(decoded) == nil)
    }
}
