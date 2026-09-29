// Tests/APITests/CourseTermPersistenceTests.swift
//
// The `term_year` / `term_season` columns (docs/course-terms.md slice 1):
// a term round-trips through the database, a course with no term reads as
// nil, and half a stored term reads as no term rather than a guess.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer
@testable import Core

@Suite(.serialized) final class CourseTermPersistenceTests {

    let app: Application

    init() async throws {
        app = try await makeTestingApplication { app in
            try await configureTestDatabase(app)
        }
    }

    private func reload(_ course: APICourse) async throws -> APICourse {
        try #require(try await APICourse.find(try course.requireID(), on: app.db))
    }

    @Test func termRoundTripsThroughTheDatabase() async throws {
        try await withApp(app) { app in
            let fall = try #require(AcademicTerm(year: 2026, season: .fall))
            let course = APICourse(code: "TERM101", name: "Term Course", term: fall)
            try await course.save(on: app.db)

            let stored = try await reload(course)
            #expect(stored.term == fall)
            #expect(stored.termYear == 2026)
            #expect(stored.termSeasonRaw == "fall")
        }
    }

    @Test func courseWithoutTermReadsAsNil() async throws {
        try await withApp(app) { app in
            let course = APICourse(code: "TERM102", name: "Legacy Course")
            try await course.save(on: app.db)
            #expect(try await reload(course).term == nil)
        }
    }

    @Test func settingNilClearsBothColumns() async throws {
        try await withApp(app) { app in
            let course = APICourse(
                code: "TERM103", name: "Term Course",
                term: AcademicTerm(year: 2027, season: .winter))
            try await course.save(on: app.db)

            course.term = nil
            try await course.save(on: app.db)
            let stored = try await reload(course)
            #expect(stored.termYear == nil)
            #expect(stored.termSeasonRaw == nil)
        }
    }

    @Test func halfATermReadsAsNoTerm() async throws {
        try await withApp(app) { app in
            let course = APICourse(code: "TERM104", name: "Term Course")
            course.termYear = 2026
            try await course.save(on: app.db)
            #expect(try await reload(course).term == nil)
        }
    }
}
