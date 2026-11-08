// Tests/APITests/Assignments/UnopenedAssignmentContentTests.swift
//
// An enrolled student must not read an assignment's content before it opens
// (#2897). `GET /api/v1/testsetups/:id/assignment` checked only enrollment,
// and the vanity link handed out the setup ID whatever the assignment's
// state. The rule is the notebook page's: open, or opened while it was.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct UnopenedAssignmentContentTests {

    /// An assignment open or closed, with a slug, and a signed-in caller
    /// enrolled with `role` ("student" or "instructor").
    private func withScenario(
        isOpen: Bool, role: String,
        _ body: @Sendable (Application, TestScenario, String) async throws -> Void
    ) async throws {
        try await withTestApp(prefix: "chickadee-unopened") { app in
            let scenario = try await TestScenario.make(on: app, setupID: "setup_unopened", isOpen: isOpen)
            scenario.assignment.slug = "lab-7"
            try await scenario.assignment.save(on: app.db)
            let cookie = try await loginUser(username: "unopened_\(role)", password: "pass", role: role, on: app)
            let user = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "unopened_\(role)").first())
            try await makeTestEnrollment(on: app, userID: try user.requireID(), courseID: scenario.courseID)
            try await body(app, scenario, cookie)
        }
    }

    private func status(_ app: Application, _ path: String, cookie: String) async throws -> HTTPStatus {
        var status: HTTPStatus = .internalServerError
        try await app.asyncTest(
            .GET, path, beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in status = res.status })
        return status
    }

    @Test(arguments: [(true, HTTPStatus.ok), (false, .forbidden)])
    func aStudentReadsTheNotebookOnlyOnceOpen(isOpen: Bool, expected: HTTPStatus) async throws {
        try await withScenario(isOpen: isOpen, role: "student") { app, scenario, cookie in
            let result = try await status(app, "/api/v1/testsetups/\(scenario.setupID)/assignment", cookie: cookie)
            #expect(result == expected)
        }
    }

    @Test func staffReadTheNotebookBeforeItOpens() async throws {
        try await withScenario(isOpen: false, role: "instructor") { app, scenario, cookie in
            let result = try await status(app, "/api/v1/testsetups/\(scenario.setupID)/assignment", cookie: cookie)
            #expect(result == .ok)
        }
    }

    @Test(arguments: [(true, HTTPStatus.seeOther), (false, .notFound)])
    func theVanityLinkNamesTheSetupOnlyOnceOpen(isOpen: Bool, expected: HTTPStatus) async throws {
        try await withScenario(isOpen: isOpen, role: "student") { app, _, cookie in
            let result = try await status(app, "/TEST101/lab-7", cookie: cookie)
            #expect(result == expected)
        }
    }
}
