// Tests/APITests/Assignments/NewAssignmentDraftLanguageRouteTests.swift
//
// `POST /instructor/new/draft` and `POST /instructor/new/save`
// (`DraftAssignmentRoutes+NewAssignment.swift`), on the paths no other suite
// reaches:
//
// - The draft save records the language the author chose in the select
//   (docs/language-declaration.md). "none" is an answer too, an upload-only
//   language also sets upload-only submission and worker grading, and an
//   unknown value is refused. The notebook scaffold follows the declaration.
// - A draft is resumed by `draftID` only by an instructor of the draft's own
//   course. An instructor of the active course who is a TA in the draft's
//   course, or who has no role there, is refused, and the draft keeps its
//   declaration.
// - A body that is not a form is refused.
// - The publish keeps the draft's suite sections and its language.
//
// `AssignmentCreationRoleFloorTests` covers the TA refusal in the active
// course, and `CrossCourseDraftRoleFloorTests` covers the save route.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class NewAssignmentDraftLanguageRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-nadl")
    }

    private struct Actor {
        let cookie: String
        let csrf: String
    }

    private struct Reply {
        let status: HTTPStatus
        let location: String?
        let body: String
    }

    private static let boundary = "Boundary-Draft-Language"
    private static let notebook = #"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#

    private func course(_ code: String) async throws -> UUID {
        try await makeTestCourse(on: app, code: code, mode: .closed).requireID()
    }

    /// An instructor of `activeCourseID` (signed in with it active) who also
    /// holds `otherRole` in `otherCourseID`, when both are given.
    private func actor(
        _ username: String, activeCourseID: UUID, otherRole: CourseRole? = nil, otherCourseID: UUID? = nil
    ) async throws -> Actor {
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        let userID = try user.requireID()
        try await APICourseEnrollment(userID: userID, courseID: activeCourseID, role: .instructor).save(on: app.db)
        let (csrf, sessionCookie) = try await csrfFields(for: "/", cookie: cookie, on: app)
        // Enrolled after the active course is set, so that course stays active.
        if let otherRole, let otherCourseID {
            try await APICourseEnrollment(userID: userID, courseID: otherCourseID, role: otherRole).save(on: app.db)
        }
        return Actor(cookie: sessionCookie, csrf: csrf)
    }

    private func post(
        _ path: String, as actor: Actor, fields: [(String, String)],
        // swiftlint:disable:next large_tuple
        files: [(name: String, filename: String, contentType: String, data: Data)] = []
    ) async throws -> Reply {
        var reply = Reply(status: .internalServerError, location: nil, body: "")
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: actor.cookie)
                req.headers.contentType = HTTPMediaType(
                    type: "multipart", subType: "form-data", parameters: ["boundary": Self.boundary])
                req.body = .init(
                    buffer: arMultipartBody(
                        boundary: Self.boundary, fields: [("_csrf", actor.csrf)] + fields, files: files))
            },
            afterResponse: { res in
                reply = Reply(
                    status: res.status, location: res.headers.first(name: .location), body: res.body.string)
            })
        return reply
    }

    /// A draft save with only a name and a language: no due date and no
    /// draft action, as a form posts when the author only picks a language.
    private func draft(
        language: String, as actor: Actor, draftID: String? = nil, action: String? = nil
    ) async throws -> Reply {
        var fields = [("assignmentName", "Language Lab"), ("assignmentLanguage", language)]
        if let draftID { fields.append(("draftID", draftID)) }
        if let action { fields.append(("draftAction", action)) }
        return try await post("/instructor/new/draft", as: actor, fields: fields)
    }

    /// The `draftID` that a draft save redirected to.
    private func draftID(from reply: Reply) throws -> String {
        let location = try #require(reply.location)
        let components = try #require(URLComponents(string: location))
        let value = try #require(components.queryItems?.first { $0.name == "draftID" }?.value)
        #expect(!value.isEmpty)
        return value
    }

    private func manifest(_ setupID: String) async throws -> TestProperties {
        let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
        return try #require(setup.decodedManifest())
    }

    private func setupCount(_ courseID: UUID) async throws -> Int {
        try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).count()
    }

    // MARK: - The draft records the declared language

    @Test(arguments: [AssignmentLanguage.r, .lua, .octave])
    func aDraftSaveDeclaresTheChosenLanguage(language: AssignmentLanguage) async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADL\(language.rawValue.uppercased())")
            let instructor = try await actor("nadl_\(language.rawValue)", activeCourseID: courseID)

            let reply = try await draft(language: language.rawValue, as: instructor)
            #expect(reply.status == .seeOther)
            let props = try await manifest(try draftID(from: reply))
            #expect(props.language == language)
            #expect(props.languageDeclared == true)
            #expect(props.submissionMode == .notebook)
        }
    }

    /// "none" is an answer: the draft records no language AND that the
    /// question was answered, which an untouched draft does not.
    @Test func noneIsRecordedAsAnAnswer() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLNONE")
            let instructor = try await actor("nadl_none", activeCourseID: courseID)

            let reply = try await draft(language: noLanguageChoice, as: instructor)
            #expect(reply.status == .seeOther)
            let props = try await manifest(try draftID(from: reply))
            #expect(props.language == nil)
            #expect(props.languageDeclared == true)
        }
    }

    @Test func anUploadOnlyLanguageSetsUploadOnlyAndWorkerGrading() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLCPP")
            let instructor = try await actor("nadl_cpp", activeCourseID: courseID)

            let reply = try await draft(language: "cpp", as: instructor)
            #expect(reply.status == .seeOther)
            let props = try await manifest(try draftID(from: reply))
            #expect(props.language == .cpp)
            #expect(props.submissionMode == .uploadOnly)
            #expect(props.gradingMode == .worker)
        }
    }

    @Test func anUnknownLanguageIsRefused() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLBAD")
            let instructor = try await actor("nadl_bad", activeCourseID: courseID)

            let reply = try await draft(language: "cobol", as: instructor)
            #expect(reply.status == .unprocessableEntity)
            #expect(reply.body.contains("Unknown assignment language"))
            // Nothing declared a language on any draft in the course.
            let setups = try await APITestSetup.query(on: app.db).filter(\.$courseID == courseID).all()
            #expect(setups.allSatisfy { $0.decodedManifest()?.languageDeclared != true })
        }
    }

    /// The scaffold reads the declaration made in the same save: an R
    /// declaration scaffolds an R notebook, not a Python one.
    @Test func theNotebookScaffoldFollowsTheDeclaredLanguage() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLSCAF")
            let instructor = try await actor("nadl_scaffold", activeCourseID: courseID)

            let reply = try await draft(language: "r", as: instructor, action: "create-assignment-notebook")
            #expect(reply.status == .seeOther)
            let setup = try #require(try await APITestSetup.find(try draftID(from: reply), on: app.db))
            let path = try #require(setup.notebookPath)
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let metadata = try #require(json["metadata"] as? [String: Any])
            let kernelspec = try #require(metadata["kernelspec"] as? [String: Any])
            guard case .notebookKernel(_, let rKernel, _, _, _) = AssignmentLanguage.r.editorSupport else {
                throw IssueRecorded("R has no notebook kernel")
            }
            #expect(kernelspec["name"] as? String == rKernel)
        }
    }

    /// An upload-only language has no notebook to scaffold, so the button is
    /// refused rather than writing a notebook no student can open.
    @Test func anUploadOnlyDeclarationRefusesTheNotebookScaffold() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLSCAFCPP")
            let instructor = try await actor("nadl_scaffold_cpp", activeCourseID: courseID)

            let reply = try await draft(language: "java", as: instructor, action: "create-assignment-notebook")
            #expect(reply.status == .unprocessableEntity)
        }
    }

    // MARK: - Resuming a draft by draftID

    @Test func anInstructorResumesTheirOwnDraft() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLRES")
            let instructor = try await actor("nadl_resume", activeCourseID: courseID)

            let first = try await draft(language: "python", as: instructor)
            let id = try draftID(from: first)
            #expect(try await setupCount(courseID) == 1)

            let second = try await draft(language: "lua", as: instructor, draftID: id)
            #expect(second.status == .seeOther)
            #expect(try draftID(from: second) == id)
            #expect(try await setupCount(courseID) == 1)
            #expect(try await manifest(id).language == .lua)
        }
    }

    /// The caller is an instructor of the active course and a TA of the
    /// draft's course. Creating an assignment is an instructor action in the
    /// draft's own course, so the draft is refused and keeps no declaration.
    @Test func aTAOfTheDraftsCourseCannotResumeIt() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("NADLTAA")
            let courseB = try await course("NADLTAB")
            try await makeTestSetup(on: app, id: "nadl_ta_draft", courseID: courseB)
            let caller = try await actor(
                "nadl_ta", activeCourseID: courseA, otherRole: .ta, otherCourseID: courseB)

            let reply = try await draft(language: "r", as: caller, draftID: "nadl_ta_draft")
            #expect(reply.status == .forbidden)
            let props = try await manifest("nadl_ta_draft")
            #expect(props.language == nil)
            #expect(props.languageDeclared != true)
            #expect(try await setupCount(courseA) == 0)
        }
    }

    @Test func anInstructorOfAnotherCourseCannotResumeADraft() async throws {
        try await withApp(app) { _ in
            let courseA = try await course("NADLXA")
            let courseB = try await course("NADLXB")
            try await makeTestSetup(on: app, id: "nadl_x_draft", courseID: courseA)
            let outsider = try await actor("nadl_x", activeCourseID: courseB)

            let reply = try await draft(language: "r", as: outsider, draftID: "nadl_x_draft")
            #expect(reply.status == .forbidden)
            #expect(try await manifest("nadl_x_draft").languageDeclared != true)
            #expect(try await setupCount(courseB) == 0)
        }
    }

    // MARK: - A body that is not a form

    @Test func aBodyThatIsNotAFormIsRefused() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLBODY")
            let instructor = try await actor("nadl_body", activeCourseID: courseID)

            var status: HTTPStatus = .internalServerError
            try await app.asyncTest(
                .POST, "/instructor/new/draft",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: instructor.cookie)
                    req.headers.add(name: .init("x-csrf-token"), value: instructor.csrf)
                    req.headers.contentType = .plainText
                    req.body = .init(string: "assignmentName=Lab")
                },
                afterResponse: { res in status = res.status })
            #expect(status == .badRequest)
            #expect(try await setupCount(courseID) == 0)
        }
    }

    // MARK: - The publish keeps the draft's sections

    @Test func publishingADraftKeepsItsSectionsAndLanguage() async throws {
        try await withApp(app) { _ in
            let courseID = try await course("NADLPUB")
            let instructor = try await actor("nadl_publish", activeCourseID: courseID)

            let id = try draftID(from: try await draft(language: "r", as: instructor))
            let draftSetup = try #require(try await APITestSetup.find(id, on: app.db))
            try await mutateManifest(setup: draftSetup, on: app.db) { props in
                var section = TestSuiteSection(id: "sec-pub", name: "Question 1")
                section.variables = [FamilyVariable(name: "max.bmi", value: .int(30))]
                props.sections = [section]
            }

            let notebook = Data(Self.notebook.utf8)
            let reply = try await post(
                "/instructor/new/save", as: instructor,
                fields: [("draftID", id), ("assignmentName", "Sectioned R Lab"), ("assignmentType", "lab")],
                files: [
                    ("assignmentNotebookFile", "assignment.ipynb", "application/json", notebook),
                    ("solutionNotebookFile", "solution.ipynb", "application/json", notebook),
                ])
            #expect(reply.status == .seeOther)
            #expect(reply.location == "/instructor")

            let assignment = try #require(
                try await APIAssignment.query(on: app.db).filter(\.$title == "Sectioned R Lab").first())
            #expect(assignment.courseID == courseID)
            let props = try await manifest(assignment.testSetupID)
            #expect(props.language == .r)
            #expect(props.languageDeclared == true)
            let section = try #require(props.sections.first)
            #expect(props.sections.count == 1)
            #expect(section.id == "sec-pub")
            #expect(section.name == "Question 1")
            #expect(section.variables.map(\.name) == ["max.bmi"])
        }
    }
}
