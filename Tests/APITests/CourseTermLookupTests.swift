// Tests/APITests/CourseTermLookupTests.swift
//
// Slice 3 of docs/course-terms.md: course codes are unique per term, so a
// code alone can name more than one active course. These tests pin the
// index, the per-term duplicate check, the URL key, and how a bare code, a
// keyed URL and an MCP `courseCode` each resolve to one offering.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class CourseTermLookupTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-term-lookup")
    }

    private let fall26 = AcademicTerm(year: 2026, season: .fall)
    private let winter27 = AcademicTerm(year: 2027, season: .winter)

    @discardableResult
    private func course(
        _ code: String, _ term: AcademicTerm?, archived: Bool = false, name: String = "Course"
    ) async throws -> APICourse {
        let course = APICourse(code: code, name: name, isArchived: archived, term: term)
        try await course.save(on: app.db)
        return course
    }

    private func enroll(_ user: APIUser, in course: APICourse, role: CourseRole = .student) async throws {
        try await APICourseEnrollment(
            userID: try user.requireID(), courseID: try course.requireID(), role: role
        ).save(on: app.db)
    }

    private func toolContext(subject: String) -> ToolContext {
        ToolContext(
            request: Request(application: app, on: app.eventLoopGroup.any()),
            subject: subject, grantedScopes: [.read, .write])
    }

    // MARK: - The unique index

    @Test func twoActiveOfferingsMayShareACodeInDifferentTerms() async throws {
        try await withApp(app) { app in
            try await course("CS135", fall26)
            try await course("CS135", winter27)
            let count = try await APICourse.query(on: app.db).filter(\.$code == "CS135").count()
            #expect(count == 2)
        }
    }

    @Test func twoActiveCoursesMayNotShareACodeAndTerm() async throws {
        try await withApp(app) { _ in
            try await course("CS136", fall26)
            await #expect(throws: (any Error).self) {
                try await self.course("CS136", self.fall26)
            }
        }
    }

    /// Without the COALESCE in the index, two NULL terms would compare as
    /// distinct and this insert would succeed.
    @Test func twoActiveCoursesWithNoTermMayNotShareACode() async throws {
        try await withApp(app) { _ in
            try await course("CS137", nil)
            await #expect(throws: (any Error).self) {
                try await self.course("CS137", nil)
            }
        }
    }

    @Test func anArchivedCourseMayShareACodeAndTerm() async throws {
        try await withApp(app) { app in
            try await course("CS138", fall26, archived: true)
            try await course("CS138", fall26)
            let count = try await APICourse.query(on: app.db).filter(\.$code == "CS138").count()
            #expect(count == 2)
        }
    }

    @Test func duplicateCheckIsPerTerm() async throws {
        try await withApp(app) { app in
            let existing = try await course("CS139", fall26)
            #expect(try await activeCourseCodeIsTaken("CS139", term: fall26, excluding: nil, on: app.db))
            #expect(!(try await activeCourseCodeIsTaken("CS139", term: winter27, excluding: nil, on: app.db)))
            #expect(!(try await activeCourseCodeIsTaken("CS139", term: nil, excluding: nil, on: app.db)))
            #expect(
                !(try await activeCourseCodeIsTaken(
                    "CS139", term: fall26, excluding: existing.requireID(), on: app.db)))
        }
    }

    // MARK: - URL key

    @Test func urlKeyIsTheCodeAloneWithoutATerm() async throws {
        try await withApp(app) { _ in
            #expect(APICourse(code: "CS135", name: "").urlKey == "CS135")
            #expect(APICourse(code: "CS135", name: "", term: fall26).urlKey == "CS135-F26")
        }
    }

    // MARK: - findActiveCourse(byKey:viewer:on:)

    @Test func aKeyNamesItsTerm() async throws {
        try await withApp(app) { app in
            let older = try await course("CS240", fall26)
            try await course("CS240", winter27)
            let found = try await findActiveCourse(byKey: "cs240-f26", viewer: nil, on: app.db)
            #expect(found?.id == older.id)
        }
    }

    @Test func aBareCodeTakesTheViewersOffering() async throws {
        try await withApp(app) { app in
            let older = try await course("CS241", fall26)
            try await course("CS241", winter27)
            let student = try await makeTestUser(on: app, username: "lookup_student")
            try await enroll(student, in: older)
            let found = try await findActiveCourse(byKey: "CS241", viewer: student.id, on: app.db)
            #expect(found?.id == older.id)
        }
    }

    @Test func aBareCodeTakesTheNewestTermOtherwise() async throws {
        try await withApp(app) { app in
            try await course("CS242", fall26)
            let newer = try await course("CS242", winter27)
            let found = try await findActiveCourse(byKey: "CS242", viewer: nil, on: app.db)
            #expect(found?.id == newer.id)
        }
    }

    @Test func anExactCodeBeatsATermSuffix() async throws {
        try await withApp(app) { app in
            let legacy = try await course("CS243-F26", nil)
            try await course("CS243", fall26)
            let found = try await findActiveCourse(byKey: "CS243-F26", viewer: nil, on: app.db)
            #expect(found?.id == legacy.id)
        }
    }

    @Test func archivedCoursesAreNotFound() async throws {
        try await withApp(app) { app in
            try await course("CS244", fall26, archived: true)
            #expect(try await findActiveCourse(byKey: "CS244-F26", viewer: nil, on: app.db) == nil)
            #expect(try await findActiveCourse(byKey: "CS244", viewer: nil, on: app.db) == nil)
        }
    }

    // MARK: - Vanity URLs

    @Test func vanityURLsResolveByKeyAndByEnrollment() async throws {
        try await withApp(app) { app in
            let older = try await course("CS245", fall26)
            let newer = try await course("CS245", winter27)
            try await makeTestSetup(on: app, id: "setup_term_old", courseID: try older.requireID())
            try await makeTestSetup(on: app, id: "setup_term_new", courseID: try newer.requireID())
            try await makeTestAssignment(
                on: app, testSetupID: "setup_term_old", courseID: try older.requireID(), title: "Lab 1")
            try await makeTestAssignment(
                on: app, testSetupID: "setup_term_new", courseID: try newer.requireID(), title: "Lab 1")

            let cookie = try await loginUser(username: "vanity_term", password: "pw", role: "user", on: app)
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "vanity_term").first())
            try await enroll(student, in: older)

            // The bare code resolves to the offering the student is in.
            try await app.asyncTest(
                .GET, "/CS245/lab-1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_term_old/notebook")
                })
            // The keyed URL names the older offering too.
            try await app.asyncTest(
                .GET, "/CS245-F26/lab-1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/testsetups/setup_term_old/notebook")
                })
            // The newer offering's key is still gated on enrollment.
            try await app.asyncTest(
                .GET, "/CS245-W27/lab-1",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    // MARK: - MCP

    @Test func mcpReadTakesTheNewestAndWriteRefusesAnAmbiguousCode() async throws {
        try await withApp(app) { app in
            let older = try await course("CS246", fall26)
            let newer = try await course("CS246", winter27)
            let instructor = try await makeTestUser(on: app, username: "term_mcp", role: "instructor")
            try await enroll(instructor, in: older, role: .instructor)
            try await enroll(instructor, in: newer, role: .instructor)
            let context = toolContext(subject: "term_mcp")

            let read = try await resolveMCPCourse(key: "CS246", tool: "t", context: context, forWrite: false)
            #expect(read.id == newer.id)

            do {
                _ = try await resolveMCPCourse(key: "CS246", tool: "t", context: context, forWrite: true)
                Issue.record("An ambiguous write must be refused")
            } catch let error as MCPToolError {
                let text = String(describing: error)
                #expect(text.contains("CS246-W27 (Winter 2027)"))
                #expect(text.contains("CS246-F26 (Fall 2026)"))
            }

            let keyed = try await resolveMCPCourse(key: "CS246-F26", tool: "t", context: context, forWrite: true)
            #expect(keyed.id == older.id)
        }
    }

    @Test func mcpPrefersActiveThenEnrolledOfferings() async throws {
        try await withApp(app) { app in
            try await course("CS247", fall26, archived: true)
            let active = try await course("CS247", winter27)
            let other = try await course("CS247", AcademicTerm(year: 2027, season: .spring))
            let instructor = try await makeTestUser(on: app, username: "term_mcp2", role: "instructor")
            try await enroll(instructor, in: active, role: .instructor)
            _ = other
            let context = toolContext(subject: "term_mcp2")

            // The archived offering loses to the active ones, and the one the
            // account teaches beats the newer one it does not, so even a
            // write resolves.
            let chosen = try await resolveMCPCourse(key: "CS247", tool: "t", context: context, forWrite: true)
            #expect(chosen.id == active.id)
        }
    }

    @Test func listCoursesReportsTermAndKey() async throws {
        try await withApp(app) { app in
            let termed = try await course("CS248", fall26, name: "Termed")
            let plain = try await course("CS249", nil, name: "Plain")
            let instructor = try await makeTestUser(on: app, username: "term_list", role: "instructor")
            try await enroll(instructor, in: termed, role: .instructor)
            try await enroll(instructor, in: plain, role: .instructor)

            let output = try await ListCoursesTool().execute(
                ListCoursesTool.Input(), toolContext(subject: "term_list"))
            #expect(output.courses.map(\.key) == ["CS248-F26", "CS249"])
            #expect(output.courses.map(\.term) == ["Fall 2026", nil])
        }
    }
}
