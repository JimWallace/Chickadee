// Tests/APITests/DataExportCourseTermTests.swift
//
// Two offerings of one course share a code, so the personal-data export
// names each course by its key and term as well, and lists the newest term
// first (#2230).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3))) final class DataExportCourseTermTests {

    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-dexp-term")
    }

    @Test func enrollmentsNameEachOfferingAndSortNewestFirst() async throws {
        try await withApp(app) { app in
            let student = try await makeTestStudent(on: app, username: "dexp_term_student")
            let fall26 = APICourse(code: "CS135", name: "Intro", term: AcademicTerm(year: 2026, season: .fall))
            let winter27 = APICourse(code: "CS135", name: "Intro", term: AcademicTerm(year: 2027, season: .winter))
            let noTerm = APICourse(code: "CS100", name: "Legacy")
            for course in [fall26, winter27, noTerm] {
                try await course.save(on: app.db)
                try await APICourseEnrollment(
                    userID: try student.requireID(), courseID: try course.requireID(), role: .student
                ).save(on: app.db)
            }

            let content = try await gatherDataExportContent(for: student, on: app.db)

            #expect(content.enrollments.map(\.courseKey) == ["CS135-W27", "CS135-F26", "CS100"])
            #expect(content.enrollments.map(\.courseTerm) == ["Winter 2027", "Fall 2026", nil])
            #expect(content.enrollments.map(\.courseCode) == ["CS135", "CS135", "CS100"])
        }
    }
}
