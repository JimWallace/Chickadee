// Tests/APITests/Assignments/PublishedSuiteSectionInputsRouteTests.swift
//
// `POST /instructor/:assignmentID/suite-sections/:sectionID/variables` on a
// published assignment (`PublishedAssignmentRoutes+SuiteSections.swift`).
// `SuiteSectionRoutesTests` covers create, rename, delete and reorder, and
// `DraftSuiteSectionRoutesTests` covers the draft twin of this route. These
// tests pin the published route:
//
// - The names are checked in the assignment's DECLARED language. An R name
//   is accepted on an R assignment and refused on a Python one. Nothing
//   infers a language from the content (docs/language-declaration.md).
// - A per-student expression on an assignment that declares no language is
//   refused, because there is no interpreter to run it in.
// - The floor is `.ta` in the assignment's own course. A TA of the course
//   writes; a student of the course, and an instructor of another course, do
//   not, and the manifest stays as it was.
//
// No test sends an expression to a declared language, so no interpreter
// subprocess runs here.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class PublishedSuiteSectionInputsRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-pssi")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    private struct InputsBody: Content {
        var variables: [FamilyVariable]
        var expressions: [PersonalizationExpression]?
    }

    private static let sectionID = "sec-q1"

    /// A manifest with one section, `sec-q1`, and `language` declared, or no
    /// language key when `language` is nil.
    private static func manifest(language: AssignmentLanguage?) -> String {
        let languageFields = language.map { #","language":"\#($0.rawValue)","languageDeclared":true"# } ?? ""
        return #"{"schemaVersion":1,"gradingMode":"worker","requiredFiles":[],"testSuites":[],"#
            + #""timeLimitSeconds":10,"makefile":null,"sections":[{"id":"sec-q1","name":"Question 1"}]"#
            + languageFields + "}"
    }

    private func course(_ code: String) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
    }

    /// An assignment in `courseID` whose manifest declares `language`.
    /// Returns the assignment's public ID.
    private func assignment(
        setupID: String, courseID: UUID, language: AssignmentLanguage?
    ) async throws -> String {
        try await makeTestSetup(
            on: app, id: setupID, courseID: courseID, manifest: Self.manifest(language: language))
        return try await makeTestAssignment(on: app, testSetupID: setupID, courseID: courseID).publicID
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

    private struct Reply {
        let status: HTTPStatus
        let location: String?
        let body: String
    }

    private func postInputs(
        assignmentID: String, body: InputsBody, as actor: Actor
    ) async throws -> Reply {
        var reply = Reply(status: .internalServerError, location: nil, body: "")
        try await app.asyncTest(
            .POST, "/instructor/\(assignmentID)/suite-sections/\(Self.sectionID)/variables",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                req.headers.add(name: .init("x-csrf-token"), value: actor.csrf)
                try req.content.encode(body, as: .json)
            },
            afterResponse: { res in
                reply = Reply(
                    status: res.status, location: res.headers.first(name: .location), body: res.body.string)
            })
        return reply
    }

    private func section(setupID: String) async throws -> TestSuiteSection {
        let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
        let props = try #require(setup.decodedManifest())
        return try #require(props.sections.first { $0.id == Self.sectionID })
    }

    /// `max.bmi` is a valid R name and not a valid Python identifier.
    private static let rOnlyName = InputsBody(
        variables: [FamilyVariable(name: "max.bmi", value: .int(30))], expressions: nil)

    // MARK: - The declared language decides the names

    @Test func aTAWritesSectionInputsInTheDeclaredLanguage() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("PSSIR")
            let aid = try await assignment(setupID: "pssi_r", courseID: courseID, language: .r)
            let ta = try await actor("pssi_r_ta", role: .ta, courseID: courseID)

            let reply = try await postInputs(assignmentID: aid, body: Self.rOnlyName, as: ta)
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor/\(aid)/edit")

            let saved = try await section(setupID: "pssi_r")
            #expect(saved.variables.map(\.name) == ["max.bmi"])
            #expect(saved.variables.first?.value == .int(30))
            #expect(saved.expressions.isEmpty)
        }
    }

    @Test func aPythonDeclarationRefusesAnRName() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("PSSIPY")
            let aid = try await assignment(setupID: "pssi_py", courseID: courseID, language: .python)
            let instructor = try await actor("pssi_py_instructor", role: .instructor, courseID: courseID)

            let reply = try await postInputs(assignmentID: aid, body: Self.rOnlyName, as: instructor)
            #expect(reply.status == .unprocessableEntity)
            #expect(reply.body.contains("Python identifier"))
            #expect(try await section(setupID: "pssi_py").variables.isEmpty)
        }
    }

    @Test func anExpressionNeedsADeclaredLanguage() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("PSSINONE")
            let aid = try await assignment(setupID: "pssi_none", courseID: courseID, language: nil)
            let instructor = try await actor("pssi_none_instructor", role: .instructor, courseID: courseID)

            let body = InputsBody(
                variables: [FamilyVariable(name: "scale", value: .double(1.5))],
                expressions: [PersonalizationExpression(name: "shift", expression: "seed % 26")])
            let reply = try await postInputs(assignmentID: aid, body: body, as: instructor)
            #expect(reply.status == .unprocessableEntity)
            #expect(reply.body.contains("declares no language"))

            let saved = try await section(setupID: "pssi_none")
            #expect(saved.variables.isEmpty)
            #expect(saved.expressions.isEmpty)
        }
    }

    /// Literal values need no interpreter, so an assignment that declares no
    /// language takes them. The names follow the cross-language rule.
    @Test func literalValuesNeedNoLanguage() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("PSSILIT")
            let aid = try await assignment(setupID: "pssi_lit", courseID: courseID, language: nil)
            let instructor = try await actor("pssi_lit_instructor", role: .instructor, courseID: courseID)

            let accepted = InputsBody(
                variables: [FamilyVariable(name: "max_bmi", value: .int(30))], expressions: nil)
            #expect(try await postInputs(assignmentID: aid, body: accepted, as: instructor).status == .seeOther)
            #expect(try await section(setupID: "pssi_lit").variables.map(\.name) == ["max_bmi"])

            // The R name is refused here: no declared language widens the rule.
            let refused = try await postInputs(assignmentID: aid, body: Self.rOnlyName, as: instructor)
            #expect(refused.status == .unprocessableEntity)
            #expect(try await section(setupID: "pssi_lit").variables.map(\.name) == ["max_bmi"])
        }
    }

    // MARK: - Per-course role gates

    @Test func aStudentOfTheCourseCannotWriteSectionInputs() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("PSSIST")
            let aid = try await assignment(setupID: "pssi_st", courseID: courseID, language: .r)
            let student = try await actor("pssi_st_student", role: .student, courseID: courseID)

            let reply = try await postInputs(assignmentID: aid, body: Self.rOnlyName, as: student)
            #expect(reply.status == .forbidden)
            #expect(try await section(setupID: "pssi_st").variables.isEmpty)
        }
    }

    @Test func anInstructorOfAnotherCourseCannotWriteSectionInputs() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("PSSIXA")
            let courseB = try await course("PSSIXB")
            let aid = try await assignment(setupID: "pssi_xa", courseID: courseA, language: .r)
            let outsider = try await actor("pssi_xb_instructor", role: .instructor, courseID: courseB)

            let reply = try await postInputs(assignmentID: aid, body: Self.rOnlyName, as: outsider)
            #expect(reply.status == .forbidden)
            #expect(try await section(setupID: "pssi_xa").variables.isEmpty)
        }
    }
}
