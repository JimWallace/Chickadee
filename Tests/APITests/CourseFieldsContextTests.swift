// Tests/APITests/CourseFieldsContextTests.swift
//
// The values behind `_course-fields.leaf` and the refusals its forms show
// (#1974). The page-level behaviour is in AdminCoursePageTests.

import Core
import Testing

@testable import APIServer

@Suite struct CourseFieldsContextTests {
    @Test func aFormWithNoTermAsksForOne() {
        let form = CourseFieldsContext(idPrefix: "x", code: "", name: "", term: nil)
        #expect(form.asksForTerm)
        #expect(!form.termOptions.contains { $0.selected })
        #expect(form.yearOptions.filter(\.selected).count == 1)
    }

    @Test func aFormWithATermSelectsIt() throws {
        let term = try #require(AcademicTerm(year: 2027, season: .winter))
        let form = CourseFieldsContext(idPrefix: "x", code: "CS1", name: "One", term: term)
        #expect(!form.asksForTerm)
        #expect(form.termOptions.filter(\.selected).map(\.value) == ["winter"])
        #expect(form.yearOptions.filter(\.selected).map(\.value) == ["2027"])
    }

    @Test(arguments: CourseFormError.allCases)
    func eachCourseFormErrorHasAMessage(_ error: CourseFormError) {
        #expect(CourseFormError.message(forQuery: error.rawValue) == error.message)
        // The settings and clone forms share one `error` query, so their codes
        // must not overlap or both panels would open.
        #expect(CourseCloneFormError.message(forQuery: error.rawValue) == nil)
    }

    @Test func anUnknownErrorCodeHasNoMessage() {
        #expect(CourseFormError.message(forQuery: "nope") == nil)
        #expect(CourseFormError.message(forQuery: nil) == nil)
    }
}
