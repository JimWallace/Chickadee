// Tests/APITests/Notebooks/LectureNotebookRoutesTests.swift
//
// Lecture notebooks (docs/lecture-notebooks.md) on the web: an ungraded
// content item whose notebook opens in the editor. Covers the service's
// create, the student notebook page (lecture mode, the published gate), the
// staff save (a student's copy is never rewritten), the reset, the
// submission refusal and the dashboard rows.

import ChickadeeTestSupport
import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) final class LectureNotebookRoutesTests: NotebookWebRoutesFixture {

    let tmpDir: String
    let publicDir: String
    let app: Application

    init() async throws {
        let fixture = try await makeNotebookWebRoutesApp()
        self.app = fixture.app
        self.tmpDir = fixture.tmpDir
        self.publicDir = fixture.publicDir
    }

    // MARK: - Helpers

    private func makeLecture(
        title: String = "Lecture 3: Data frames", markdown: String? = nil, isPublished: Bool = true
    ) async throws -> (item: APICourseContentItem, setupID: String) {
        let draft = try ContentItemDraft(
            title: title, kind: ContentItemKind.notebook.rawValue, links: [], description: nil,
            updatedLabel: nil, isPublished: isPublished)
        let item = try await LectureNotebookService.create(
            draft, language: .python, notebookData: markdown.map { Data(notebookJSON(markdown: $0).utf8) },
            in: (try await makeCourse().requireID(), nil),
            setupsDirectory: app.testSetupsDirectory, on: app.db)
        return (item, try #require(item.lectureTestSetupID))
    }

    private func studentCookie(username: String) async throws -> (cookie: String, user: APIUser) {
        let cookie = try await loginUser(username: username, password: "testpassword", role: "student", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await enroll(user)
        return (cookie, user)
    }

    // MARK: - Create

    @Test func createMakesASetupWithNoAssignmentThatDeclaresTheLanguage() async throws {
        try await withApp(app) { _ in
            let (item, setupID) = try await makeLecture()
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            // No assignment row: that absence keeps a lecture out of grading.
            #expect(try await assignmentByTestSetupID(setupID, on: app.db) == nil)
            #expect(LectureNotebookService.declaredLanguage(of: setup) == .python)
            #expect(item.kind == .notebook)
            let notebook = try String(contentsOfFile: try #require(setup.notebookPath), encoding: .utf8)
            // A blank lecture notebook carries the title, not assignment copy.
            #expect(notebook.contains("Lecture 3: Data frames"))
            #expect(!notebook.contains("assignment instructions"))
            #expect(notebook.contains("\"kernelspec\""))
        }
    }

    @Test func languageHasNoDefaultAndMustHaveAnEditor() async throws {
        // Every test in this class suite runs inside `withApp`, which shuts
        // down the app `init` built; a body without it trips Vapor's deinit
        // assertion.
        try await withApp(app) { _ in
            #expect(throws: CourseContentError.lectureLanguageRequired(given: nil)) {
                try LectureNotebookService.parseLanguage(nil)
            }
            #expect(throws: CourseContentError.lectureLanguageRequired(given: "cobol")) {
                try LectureNotebookService.parseLanguage("cobol")
            }
            for language in AssignmentLanguage.allCases where !LectureNotebookService.hasEditor(language) {
                #expect(throws: CourseContentError.lectureLanguageHasNoEditor(language)) {
                    try LectureNotebookService.parseLanguage(language.rawValue)
                }
            }
            for language in AssignmentLanguage.allCases where LectureNotebookService.hasEditor(language) {
                #expect((try? LectureNotebookService.parseLanguage(language.rawValue)) == language)
            }
        }
    }

    // MARK: - Student page

    @Test func studentOpensAPublishedLectureWithNoSubmitAndNoGrading() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeLecture(markdown: "Example code for the lecture")
            let (cookie, student) = try await studentCookie(username: "lecture_student_open")

            let response = try await getResponse("/testsetups/\(setupID)/notebook", cookie: cookie, on: app)
            #expect(response.status == .ok)
            let body = response.body.string
            #expect(body.contains("Lecture 3: Data frames"))
            #expect(!body.contains("id=\"nb-submit\""))
            #expect(!body.contains("id=\"nb-upload-file\""))
            #expect(body.contains("data-grading-mode=\"none\""))
            #expect(body.contains("Reset to the instructor"))

            // The student's own copy is seeded from the instructor's notebook.
            let copy = try String(
                contentsOfFile: workingCopyPath(setupID: setupID, userID: try student.requireID()), encoding: .utf8)
            #expect(copy.contains("Example code for the lecture"))
        }
    }

    @Test func studentCannotReachAHiddenLecture() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeLecture(isPublished: false)
            let (cookie, _) = try await studentCookie(username: "lecture_student_hidden")
            for path in [
                "/testsetups/\(setupID)/notebook", "/testsetups/\(setupID)/notebook/source",
                "/api/v1/testsetups/\(setupID)/assignment/download",
            ] {
                let response = try await getResponse(path, cookie: cookie, on: app)
                #expect(response.status == .notFound || response.status == .forbidden, "GET \(path)")
            }
            // Staff reach it while it is hidden.
            let staff = try await staffCookie(username: "lecture_staff_hidden")
            let staffResponse = try await getResponse("/testsetups/\(setupID)/notebook", cookie: staff, on: app)
            #expect(staffResponse.status == .ok)
        }
    }

    @Test func aLectureHasNoSolutionView() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeLecture()
            let staff = try await staffCookie(username: "lecture_staff_solution")
            let response = try await getResponse(
                "/testsetups/\(setupID)/notebook?file=solution", cookie: staff, on: app)
            #expect(response.status == .notFound)
        }
    }

    // MARK: - Staff save, student copy, reset

    @Test func staffSaveChangesNewCopiesButNeverAnExistingOne() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeLecture(markdown: "Version one")
            let (studentCookie, student) = try await studentCookie(username: "lecture_student_save")
            let studentCopyPath = workingCopyPath(setupID: setupID, userID: try student.requireID())
            _ = try await getResponse("/testsetups/\(setupID)/notebook", cookie: studentCookie, on: app)
            #expect(try String(contentsOfFile: studentCopyPath, encoding: .utf8).contains("Version one"))

            let staff = try await staffCookie(username: "lecture_staff_save")
            let editView = try await getResponse("/testsetups/\(setupID)/notebook?edit=1", cookie: staff, on: app)
            #expect(editView.body.string.contains("Save lecture notebook"))
            let edited = notebookJSON(markdown: "Version two")
            try await postNotebookSave(setupID: setupID, cookie: staff, body: edited) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Lecture notebook saved"))
            }
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            #expect(
                try String(contentsOfFile: try #require(setup.notebookPath), encoding: .utf8).contains("Version two"))
            // No assignment appeared, and no version history was started.
            #expect(try await assignmentByTestSetupID(setupID, on: app.db) == nil)

            // The student's copy is their own work and is not rewritten.
            _ = try await getResponse("/testsetups/\(setupID)/notebook", cookie: studentCookie, on: app)
            #expect(try String(contentsOfFile: studentCopyPath, encoding: .utf8).contains("Version one"))

            // A reset gives them the instructor's current version, and returns
            // them to the editor.
            let (csrf, session) = try await csrfFields(for: "/account", cookie: studentCookie, on: app)
            try await app.asyncTest(
                .POST, "/testsetups/\(setupID)/reset-notebook",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: session)
                    req.headers.add(name: "x-csrf-token", value: csrf)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/testsetups/\(setupID)/notebook")
                })
            #expect(try String(contentsOfFile: studentCopyPath, encoding: .utf8).contains("Version two"))
        }
    }

    @Test func staffCannotSaveASolutionToALecture() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeLecture()
            let staff = try await staffCookie(username: "lecture_staff_nosolution")
            try await postNotebookSave(
                setupID: setupID, cookie: staff, file: "solution", body: notebookJSON(markdown: "Answers")
            ) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    // MARK: - Submissions

    @Test func theSubmissionGateRefusesALecture() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeLecture()
            let (_, student) = try await studentCookie(username: "lecture_student_submit")
            let req = makeTestRequest(on: app)
            req.auth.login(student)
            await #expect(throws: AssignmentSubmissionGateError.lectureNotebook) {
                _ = try await requireOpenStudentAssignment(for: setupID, user: student, gate: .submission, on: req)
            }
            // Reading it is not a submission, so the access gate lets it pass.
            let access = try await requireOpenStudentAssignment(for: setupID, user: student, gate: .access, on: req)
            #expect(access == nil)
        }
    }

    // MARK: - Dashboards and delete

    @Test func theCourseRowsOpenTheNotebookAndTheSetupIsNotADraft() async throws {
        try await withApp(app) { _ in
            let (_, setupID) = try await makeLecture(title: "Lecture on dashboards")
            let staff = try await staffCookie(username: "lecture_staff_dashboard")
            let instructor = try await getResponse("/instructor", cookie: staff, on: app).body.string
            #expect(instructor.contains("Lecture on dashboards"))
            #expect(instructor.contains("/testsetups/\(setupID)/notebook?edit=1"))
            // The setup shows only through its item's two actions (open and
            // edit), never as an unpublished draft row of its own.
            #expect(instructor.components(separatedBy: setupID).count - 1 == 2)

            let (studentCookie, _) = try await studentCookie(username: "lecture_student_dashboard")
            let dashboard = try await getResponse("/", cookie: studentCookie, on: app).body.string
            #expect(dashboard.contains("Lecture on dashboards"))
            #expect(dashboard.contains("/testsetups/\(setupID)/notebook"))
            #expect(!dashboard.contains("/testsetups/\(setupID)/notebook?edit=1"))
        }
    }

    @Test func deletingTheItemDeletesItsSetup() async throws {
        try await withApp(app) { _ in
            let (item, setupID) = try await makeLecture()
            let setup = try #require(try await APITestSetup.find(setupID, on: app.db))
            let notebookPath = try #require(setup.notebookPath)
            try await CourseContentService.delete(item, application: app, on: app.db)
            #expect(try await APITestSetup.find(setupID, on: app.db) == nil)
            #expect(!FileManager.default.fileExists(atPath: notebookPath))
        }
    }

    @Test func aLectureCannotBeAttachedOrTurnedIntoAnotherKind() async throws {
        try await withApp(app) { _ in
            let (item, setupID) = try await makeLecture()
            _ = try await insertSetup(id: "setup_lecture_attach", notebookJSON: notebookJSON(markdown: "Lab"))
            let assignment = try await insertAssignment(testSetupID: "setup_lecture_attach", title: "Lab")
            await #expect(throws: CourseContentError.lectureCannotAttach) {
                try await CourseContentService.attach(item, toAssignment: try assignment.requireID(), on: app.db)
            }
            #expect(throws: CourseContentError.notALectureNotebook) {
                try CourseContentService.apply(ContentItemEdit(kind: "slides"), to: item)
            }
            _ = setupID
        }
    }
}
