// Tests/APITests/WorkbenchPreviewRoutesTests.swift
//
// Preview as student (notebook views NB6b): the workbench lists the course's
// students, opens the starter as one student gets it (personalized and
// read-only, with that student's guide), and refuses a token that names no
// student of the course. A student cannot reach either route.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct WorkbenchPreviewRoutesTests {

    private struct Fixture {
        /// The instructor's and the student's session cookies.
        let staff: String
        let student: String
        /// The student's and the instructor's `urlToken`.
        let token: String
        let staffToken: String
        let assignment: APIAssignment
    }

    private let manifest = """
        {"schemaVersion":1,"gradingMode":"browser","language":"python","requiredFiles":[],\
        "sections":[{"id":"s1","name":"Task 1: Greet"}],\
        "testSuites":[{"tier":"public","script":"test_a.py","sectionID":"s1"}],"timeLimitSeconds":10,\
        "globalVariables":[{"name":"greeting","value":"hello"}]}
        """

    private let starter = """
        {"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[\
        {"cell_type":"markdown","metadata":{},"source":["## Task 1: Greet"]},\
        {"cell_type":"code","metadata":{},"execution_count":null,"outputs":[],"source":["word = \\"{{greeting}}\\""]}]}
        """

    /// An instructor, a student who has signed in to the course, and an
    /// assignment whose starter carries a placeholder.
    private func fixture(
        _ app: Application, id: String
    ) async throws
        -> Fixture
    {
        // The course first: a student who signs in to an `.auto` course is
        // enrolled in it as a student.
        let courseID = try await app.testCourseID(enrollmentMode: .auto)
        let studentCookie = try await arLoginAsStudent(on: app)
        let staffCookie = try await arLoginAsInstructor(on: app)
        let setup = try await makeTestSetup(on: app, id: id, courseID: courseID, manifest: manifest)
        let notebookPath = try #require(setup.notebookPath)
        try starter.write(toFile: notebookPath, atomically: true, encoding: .utf8)
        let assignment = try await arInsertAssignment(testSetupID: id, title: "Greet Lab", isOpen: true, on: app)
        let student = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
        let staff = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
        return Fixture(
            staff: staffCookie, student: studentCookie, token: try student.requireURLToken(),
            staffToken: try staff.requireURLToken(), assignment: assignment)
    }

    @Test func theWorkbenchListsTheStudents() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, id: "setup_preview_list")
            try await app.asyncTest(
                .GET, "/instructor/\(fx.assignment.publicID)/workbench",
                beforeRequest: { req in req.headers.add(name: .cookie, value: fx.staff) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("Preview as student ▾"))
                    #expect(html.contains("data-wb-target-view=\"student:\(fx.token)\""))
                    #expect(html.contains("assignment:student:\(fx.token)"))
                    // Staff are not students.
                    #expect(!html.contains("data-wb-target-view=\"student:\(fx.staffToken)\""))
                })
        }
    }

    @Test func aPreviewIsTheStudentsStarterReadOnly() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, id: "setup_preview_open")
            try await app.asyncTest(
                .GET,
                "/instructor/\(fx.assignment.publicID)/workbench?file=assignment&view=personalized&as=\(fx.token)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: fx.staff) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let html = res.body.string
                    #expect(html.contains("data-read-only=\"true\""))
                    #expect(html.contains("data-wb-view=\"student:\(fx.token)\""))
                    #expect(html.contains("/instructor/\(fx.assignment.publicID)/preview-guide.json?as=\(fx.token)"))
                    #expect(html.contains("Preview: teststudent ▾"))
                    #expect(!html.contains("id=\"nb-submit\""))
                })

            // The preview file is the starter with the student's values.
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
            let path =
                app.directory.publicDirectory + "jupyterlite/files/users/"
                + "\(try staff.requireID().uuidString.lowercased())/setup_preview_open/preview-\(fx.token).ipynb"
            let preview = try String(contentsOfFile: path, encoding: .utf8)
            #expect(preview.contains("hello"))
            #expect(!preview.contains("{{greeting}}"))

            // The student's own working copy is not made or touched.
            let student = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
            let studentDir =
                app.directory.publicDirectory + "jupyterlite/files/users/"
                + "\(try student.requireID().uuidString.lowercased())/setup_preview_open"
            #expect(!FileManager.default.fileExists(atPath: studentDir))
        }
    }

    @Test func aStudentOfAnotherCourseIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, id: "setup_preview_other")
            let other = try await makeTestCourse(on: app, code: "OTHER101")
            let outsider = try await makeTestUser(on: app, username: "outsider", role: "student")
            try await makeTestEnrollment(on: app, userID: try outsider.requireID(), courseID: try other.requireID())
            let token = try outsider.requireURLToken()
            try await app.asyncTest(
                .GET, "/instructor/\(fx.assignment.publicID)/workbench?file=assignment&view=personalized&as=\(token)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: fx.staff) },
                afterResponse: { res in #expect(res.status == .notFound) })
            try await app.asyncTest(
                .GET, "/instructor/\(fx.assignment.publicID)/preview-guide.json?as=\(token)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: fx.staff) },
                afterResponse: { res in #expect(res.status == .notFound) })
        }
    }

    @Test func aTokenOutsideTheGeneratedAlphabetIsNotAPreview() {
        #expect(InstructorWorkbenchRoutes.isPreviewToken("ab12cd34"))
        #expect(!InstructorWorkbenchRoutes.isPreviewToken(""))
        #expect(!InstructorWorkbenchRoutes.isPreviewToken("../x"))
        #expect(!InstructorWorkbenchRoutes.isPreviewToken("AB12"))
    }

    @Test func thePreviewGuideIsTheStudentsWithNoAttempt() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, id: "setup_preview_guide")
            try await app.asyncTest(
                .GET, "/instructor/\(fx.assignment.publicID)/preview-guide.json?as=\(fx.token)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: fx.staff) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let guide = try JSONDecoder().decode(NotebookGuide.self, from: Data(res.body.string.utf8))
                    #expect(guide.attempt == nil)
                    #expect(guide.tasks.map(\.heading) == ["Task 1: Greet"])
                })
        }
    }

    @Test func aTokenThatNamesNoStudentIsRefused() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, id: "setup_preview_bad")
            let staff = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "testinstructor").first())
            for token in ["nosuchtk", try staff.requireURLToken()] {
                try await app.asyncTest(
                    .GET,
                    "/instructor/\(fx.assignment.publicID)/workbench?file=assignment&view=personalized&as=\(token)",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: fx.staff) },
                    afterResponse: { res in #expect(res.status == .notFound) })
                try await app.asyncTest(
                    .GET, "/instructor/\(fx.assignment.publicID)/preview-guide.json?as=\(token)",
                    beforeRequest: { req in req.headers.add(name: .cookie, value: fx.staff) },
                    afterResponse: { res in #expect(res.status == .notFound) })
            }
        }
    }

    @Test func aStudentCannotPreview() async throws {
        try await withAssignmentRoutesApp { app in
            let fx = try await fixture(app, id: "setup_preview_student")
            try await app.asyncTest(
                .GET, "/instructor/\(fx.assignment.publicID)/preview-guide.json?as=\(fx.token)",
                beforeRequest: { req in req.headers.add(name: .cookie, value: fx.student) },
                afterResponse: { res in
                    #expect(res.status != .ok)
                    #expect(!res.body.string.contains("Task 1: Greet"))
                })
        }
    }
}
