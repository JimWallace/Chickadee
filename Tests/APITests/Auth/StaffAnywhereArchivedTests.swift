// Tests/APITests/Auth/StaffAnywhereArchivedTests.swift
//
// #2663: `isStaffAnywhere` takes an explicit `includingArchived`. The
// deployment-wide file trees pass `false`, so a TA whose only staff course is
// archived is a student there (#1756). The MCP and OAuth gates pass `true`, so
// an archived course stays readable through MCP (`MCPArchivedWriteBlockTests`
// pins that half).

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite struct StaffAnywhereArchivedTests {

    /// One course enrollment of the user under test.
    struct Enrollment: Sendable {
        let role: CourseRole
        let archived: Bool
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let label: String
        let enrollments: [Enrollment]
        let includingArchived: Bool
        let expected: Bool
        var testDescription: String { label }
    }

    static let cases: [Case] = [
        Case(
            label: "TA in a live course, archived excluded",
            enrollments: [Enrollment(role: .ta, archived: false)],
            includingArchived: false, expected: true),
        Case(
            label: "TA in a live course, archived included",
            enrollments: [Enrollment(role: .ta, archived: false)],
            includingArchived: true, expected: true),
        Case(
            label: "TA in an archived course only, archived excluded",
            enrollments: [Enrollment(role: .ta, archived: true)],
            includingArchived: false, expected: false),
        Case(
            label: "TA in an archived course only, archived included",
            enrollments: [Enrollment(role: .ta, archived: true)],
            includingArchived: true, expected: true),
        Case(
            label: "Instructor in an archived course only, archived excluded",
            enrollments: [Enrollment(role: .instructor, archived: true)],
            includingArchived: false, expected: false),
        Case(
            label: "Past-term TA who is a student now, archived excluded",
            enrollments: [Enrollment(role: .ta, archived: true), Enrollment(role: .student, archived: false)],
            includingArchived: false, expected: false),
        Case(
            label: "Past-term TA who is a student now, archived included",
            enrollments: [Enrollment(role: .ta, archived: true), Enrollment(role: .student, archived: false)],
            includingArchived: true, expected: true),
        Case(
            label: "Student in a live course, archived included",
            enrollments: [Enrollment(role: .student, archived: false)],
            includingArchived: true, expected: false),
    ]

    @Test(arguments: cases)
    func staffAnywhereHonoursIncludingArchived(_ testCase: Case) async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let user = try await makeTestUser(on: app, username: "subject")
            for (index, enrollment) in testCase.enrollments.enumerated() {
                let course = try await makeTestCourse(
                    on: app, code: "SA\(index)", archived: enrollment.archived, mode: .closed)
                try await APICourseEnrollment(
                    userID: try user.requireID(), courseID: try course.requireID(), role: enrollment.role
                ).save(on: app.db)
            }
            let result = try await isStaffAnywhere(
                user, includingArchived: testCase.includingArchived, db: app.db)
            #expect(result == testCase.expected)
        }
    }

    @Test(arguments: [false, true])
    func adminIsStaffWhatever(includingArchived: Bool) async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let admin = try await makeTestUser(on: app, username: "admin-subject", role: "admin")
            #expect(try await isStaffAnywhere(admin, includingArchived: includingArchived, db: app.db))
        }
    }

    // MARK: - The user-file namespace refuses a past-term TA

    private struct InjectAuthMiddleware: AsyncMiddleware {
        let user: APIUser

        func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
            request.auth.login(user)
            return try await next.respond(to: request)
        }
    }

    private func makeNamespaceApp(user: APIUser) async throws -> Application {
        try await makeTestingApplication { app in
            try await configureTestDatabase(app)
            app.middleware.use(InjectAuthMiddleware(user: user))
            app.middleware.use(UserFileNamespaceMiddleware())
            app.get("jupyterlite", "files", "users", ":userID", "assignment.ipynb") { _ in
                Response(status: .ok, body: .init(string: "notebook"))
            }
        }
    }

    /// A TA reaches another user's folder only while the course is live. The
    /// live case is the control: it shows that the refusal comes from the
    /// archived state, not from the route or the fixture.
    @Test(arguments: [(archived: false, expected: HTTPStatus.ok), (archived: true, expected: .forbidden)])
    func userFileNamespaceAdmitsOnlyLiveCourseTA(archived: Bool, expected: HTTPStatus) async throws {
        let ta = APIUser(id: UUID(), username: "namespace-ta", passwordHash: "unused", role: "student")
        try await withApp(try await makeNamespaceApp(user: ta)) { app in
            try await ta.save(on: app.db)
            let course = try await makeTestCourse(on: app, code: "NSTA", archived: archived, mode: .closed)
            try await APICourseEnrollment(
                userID: try ta.requireID(), courseID: try course.requireID(), role: .ta
            ).save(on: app.db)
            try await app.asyncTest(
                .GET, "/jupyterlite/files/users/\(UUID().uuidString.lowercased())/assignment.ipynb"
            ) { res in
                #expect(res.status == expected)
            }
        }
    }
}
