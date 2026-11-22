// Tests/APITests/Assignments/PublishedGlobalVariablesRouteTests.swift
//
// `GET` and `PUT /instructor/:assignmentID/global-variables` on a published
// assignment (`PublishedAssignmentRoutes+GlobalVariables.swift`).
// `GlobalInputsServiceValidationTests` covers the validation rules of the
// service under the route. These tests pin the route itself:
//
// - A TA of the course replaces the literal values. The reply carries the
//   saved lists, the manifest holds them, and a later GET reads them back.
// - A refusal from the service reaches the caller as 422 and changes nothing.
// - A student of the course cannot write, and the manifest stays as it was.
//
// No test sends an expression, so no interpreter subprocess runs here.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class PublishedGlobalVariablesRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-pgv")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    private struct InputsBody: Content {
        var variables: [FamilyVariable]
        var expressions: [PersonalizationExpression]?
    }

    private static let manifest =
        #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"#
        + #""timeLimitSeconds":10,"makefile":null,"language":"python","languageDeclared":true}"#

    /// A course with one published assignment. Returns the course ID and the
    /// assignment's public ID.
    private func assignment(code: String, setupID: String) async throws -> (UUID, String) {
        let courseID = try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: Self.manifest)
        let publicID = try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID).publicID
        return (courseID, publicID)
    }

    /// `username`, enrolled in `courseID` at `role` (their only course, so it
    /// is the active one), signed in.
    private func actor(_ username: String, role: CourseRole, courseID: UUID) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    private func put(
        assignmentID: String, body: InputsBody, as actor: Actor
    ) async throws -> (status: HTTPStatus, body: String) {
        var reply: (status: HTTPStatus, body: String) = (.internalServerError, "")
        try await app.asyncTest(
            .PUT, "/instructor/\(assignmentID)/global-variables",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                req.headers.add(name: .init("x-csrf-token"), value: actor.csrf)
                try req.content.encode(body, as: .json)
            },
            afterResponse: { res in
                reply = (res.status, res.body.string)
            })
        return reply
    }

    private func savedVariables(setupID: String) async throws -> [FamilyVariable] {
        let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
        return try #require(setup.decodedManifest()).globalVariables
    }

    @Test func aTAReplacesTheValuesAndReadsThemBack() async throws {
        try await withApp(app) { _ in
            let (courseID, aid) = try await assignment(code: "PGVTA", setupID: "pgv_ta")
            let ta = try await actor("pgv_ta", role: .ta, courseID: courseID)
            let body = InputsBody(
                variables: [
                    FamilyVariable(name: "cap", value: .int(5)),
                    FamilyVariable(name: "label", value: .string("systolic")),
                ],
                expressions: nil)

            let reply = try await put(assignmentID: aid, body: body, as: ta)
            #expect(reply.status == .ok, "\(reply.body)")
            let saved = try JSONDecoder().decode(
                PublishedAssignmentRoutes.GlobalVariablesResponse.self, from: Data(reply.body.utf8))
            #expect(saved.variables == body.variables)
            #expect(saved.expressions.isEmpty)
            #expect(try await savedVariables(setupID: "pgv_ta") == body.variables)

            try await app.asyncTest(
                .GET, "/instructor/\(aid)/global-variables",
                beforeRequest: { req in req.headers.add(name: .cookie, value: ta.cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let read = try res.content.decode(PublishedAssignmentRoutes.GlobalVariablesResponse.self)
                    #expect(read.variables == body.variables)
                    #expect(read.expressions.isEmpty)
                })

            // An empty list clears the values.
            let cleared = try await put(assignmentID: aid, body: InputsBody(variables: [], expressions: []), as: ta)
            #expect(cleared.status == .ok)
            #expect(try await savedVariables(setupID: "pgv_ta").isEmpty)
        }
    }

    @Test func aRefusedSaveIsUnprocessableAndChangesNothing() async throws {
        try await withApp(app) { _ in
            let (courseID, aid) = try await assignment(code: "PGVDUP", setupID: "pgv_dup")
            let instructor = try await actor("pgv_dup", role: .instructor, courseID: courseID)
            let repeated = InputsBody(
                variables: [
                    FamilyVariable(name: "cap", value: .int(5)),
                    FamilyVariable(name: "cap", value: .int(6)),
                ],
                expressions: nil)

            let reply = try await put(assignmentID: aid, body: repeated, as: instructor)
            #expect(reply.status == .unprocessableEntity)
            #expect(try await savedVariables(setupID: "pgv_dup").isEmpty)
        }
    }

    @Test func aStudentOfTheCourseCannotWriteTheValues() async throws {
        try await withApp(app) { _ in
            let (courseID, aid) = try await assignment(code: "PGVST", setupID: "pgv_st")
            let student = try await actor("pgv_st", role: .student, courseID: courseID)
            let body = InputsBody(variables: [FamilyVariable(name: "cap", value: .int(5))], expressions: nil)

            let reply = try await put(assignmentID: aid, body: body, as: student)
            #expect(reply.status == .forbidden)
            #expect(try await savedVariables(setupID: "pgv_st").isEmpty)
        }
    }
}
