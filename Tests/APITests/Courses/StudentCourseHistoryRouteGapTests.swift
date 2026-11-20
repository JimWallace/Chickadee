// Tests/APITests/Courses/StudentCourseHistoryRouteGapTests.swift
//
// Coverage gaps in `StudentCourseRoutes+History.swift`, the staff pages and
// actions under `/:courseCode/students/:urlToken/...`:
//
//  * the per-student page groups rows under their course section, shows a
//    class-record badge (and hides one the setup disabled), and gives the
//    latest attempt the jump badge that the prior attempt's grade earns;
//  * an unknown course code and an assignment of another course are 404;
//  * an extension with no date or an unparseable date is refused;
//  * the per-student notebook reset writes the starter and redirects back,
//    and is refused when the setup has no starter;
//  * a per-course student, and staff of another course, are refused.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct StudentCourseHistoryRouteGapTests {

    /// An instructor session on TEST101 plus one enrolled student.
    private struct Staffed {
        let cookie: String
        let student: APIUser
        let urlToken: String
    }

    private func staffedCourse(studentName: String, on app: Application) async throws -> Staffed {
        let cookie = try await arLoginAsInstructor(on: app)
        let student = try await arInsertStudent(username: studentName, on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        return Staffed(cookie: cookie, student: student, urlToken: try student.requireURLToken())
    }

    private func manifestJSON(_ props: TestProperties) throws -> String {
        try #require(String(bytes: try JSONEncoder().encode(props), encoding: .utf8))
    }

    private func post(
        _ path: String, form: [String: String], cookie: String, on app: Application
    ) async throws -> TestResponse {
        let (csrf, sessionCookie) = try await csrfFields(for: "/instructor", cookie: cookie, on: app)
        var fields = form
        fields["_csrf"] = csrf
        return try await app.asyncSendRequest(.POST, path) { req in
            req.headers.add(name: .cookie, value: sessionCookie)
            try req.content.encode(fields, as: .urlEncodedForm)
        }
    }

    // MARK: - Per-student submissions page

    @Test func anAssignmentInACourseSectionIsListedUnderThatSection() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_section_student", on: app)
            let section = APICourseSection(
                name: "Week Three Labs", sortOrder: 0,
                courseID: try await app.testCourseID(enrollmentMode: .auto))
            try await section.save(on: app.db)
            try await arInsertSetup(id: "gap_section_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "gap_section_setup", title: "Sectioned Lab", isOpen: true, on: app)
            assignment.sectionID = try section.requireID()
            try await assignment.save(on: app.db)

            let html = try await getHTML(
                StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: staffed.urlToken),
                cookie: staffed.cookie, on: app)
            #expect(html.contains("Week Three Labs"), "a section that holds a row shows its heading")
            #expect(html.contains("Sectioned Lab"))
        }
    }

    @Test func aClassRecordTheStudentHoldsShowsAsABadge() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_record_student", on: app)
            try await arInsertSetup(id: "gap_record_setup", on: app)
            try await arInsertAssignment(
                testSetupID: "gap_record_setup", title: "Record Lab", isOpen: true, on: app)
            let submission = try await arInsertSubmission(
                id: "gap_record_sub", testSetupID: "gap_record_setup",
                userID: try staffed.student.requireID(), on: app)
            try await APIClassAchievement(
                testSetupID: "gap_record_setup", achievementID: "pathfinder",
                userID: try staffed.student.requireID(), submissionID: try submission.requireID()
            ).save(on: app.db)

            let html = try await getHTML(
                StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: staffed.urlToken),
                cookie: staffed.cookie, on: app)
            #expect(html.contains("Pathfinder"))
        }
    }

    @Test func aClassRecordTheSetupDisabledDoesNotShow() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_disabled_student", on: app)
            let manifest = try manifestJSON(
                TestProperties(language: nil, disabledBuiltInAwardIDs: ["pathfinder"]))
            try await arInsertSetup(id: "gap_disabled_setup", manifest: manifest, on: app)
            try await arInsertAssignment(
                testSetupID: "gap_disabled_setup", title: "Disabled Lab", isOpen: true, on: app)
            let submission = try await arInsertSubmission(
                id: "gap_disabled_sub", testSetupID: "gap_disabled_setup",
                userID: try staffed.student.requireID(), on: app)
            try await APIClassAchievement(
                testSetupID: "gap_disabled_setup", achievementID: "pathfinder",
                userID: try staffed.student.requireID(), submissionID: try submission.requireID()
            ).save(on: app.db)

            let html = try await getHTML(
                StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: staffed.urlToken),
                cookie: staffed.cookie, on: app)
            #expect(html.contains("Disabled Lab"))
            #expect(!html.contains("Pathfinder"))
        }
    }

    /// Attempt 1 scores 0%, attempt 2 scores 100%: the 100-point jump earns
    /// the built-in jump badge, which reads the prior attempt's grade.
    @Test func theLatestAttemptEarnsTheJumpBadgeFromThePriorGrade() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_rally_student", on: app)
            let studentID = try staffed.student.requireID()
            try await arInsertSetup(id: "gap_rally_setup", on: app)
            try await arInsertAssignment(
                testSetupID: "gap_rally_setup", title: "Jump Lab", isOpen: true, on: app)

            let first = try await arInsertSubmission(
                id: "gap_rally_sub1", testSetupID: "gap_rally_setup", userID: studentID,
                attemptNumber: 1, on: app)
            first.submittedAt = Date(timeIntervalSinceNow: -3_600)
            try await first.save(on: app.db)
            try await wrInsertResult(
                submissionID: "gap_rally_sub1",
                outcomes: [wrMakeOutcome(name: "t1", status: .fail)], on: app)

            let second = try await arInsertSubmission(
                id: "gap_rally_sub2", testSetupID: "gap_rally_setup", userID: studentID,
                attemptNumber: 2, on: app)
            second.submittedAt = Date()
            try await second.save(on: app.db)
            try await wrInsertResult(
                submissionID: "gap_rally_sub2",
                outcomes: [wrMakeOutcome(name: "t1", status: .pass)], on: app)

            let html = try await getHTML(
                StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: staffed.urlToken),
                cookie: staffed.cookie, on: app)
            #expect(html.contains("Rally"))
        }
    }

    // MARK: - Not found

    @Test func anUnknownCourseCodeIsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_nocourse_student", on: app)
            let response = try await getResponse(
                StudentCoursePaths.submissions(courseCode: "NOPE999", urlToken: staffed.urlToken),
                cookie: staffed.cookie, on: app)
            #expect(response.status == .notFound)
        }
    }

    @Test func anAssignmentOfAnotherCourseIsNotFound() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_cross_student", on: app)
            let other = try await makeCourseWithAssignment(
                code: "GAPOTHER", archived: false, enrollmentMode: .closed, setupPrefix: "gap_other_",
                on: app)
            let path = StudentCoursePaths.assignmentHistory(
                courseCode: "TEST101", urlToken: staffed.urlToken, assignmentID: other.assignmentID)
            let response = try await getResponse(path, cookie: staffed.cookie, on: app)
            #expect(response.status == .notFound)
        }
    }

    // MARK: - Extension refusals

    @Test(arguments: ["", "   ", "not a date"])
    func anExtensionWithoutAValidDateIsRefused(rawDate: String) async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_ext_student", on: app)
            try await arInsertSetup(id: "gap_ext_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "gap_ext_setup", title: "Extension Lab", isOpen: true, on: app)

            let response = try await post(
                StudentCoursePaths.extensionSave(
                    courseCode: "TEST101", urlToken: staffed.urlToken,
                    assignmentID: assignment.publicID),
                form: ["extendedDueAt": rawDate, "note": "travel"],
                cookie: staffed.cookie, on: app)
            #expect(response.status == .badRequest)

            let rows = try await APIAssignmentExtension.query(on: app.db)
                .filter(\.$assignmentID == (try assignment.requireID()))
                .count()
            #expect(rows == 0, "a refused extension must not write a row")
        }
    }

    // MARK: - Notebook reset

    @Test func theNotebookResetWritesTheStarterAndRedirectsToTheStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_reset_student", on: app)
            let studentID = try staffed.student.requireID()
            let setup = try await arInsertSetup(id: "gap_reset_setup", on: app)
            try await arAttachStarterNotebook(
                to: setup,
                bytes: Data(
                    #"""
                    {"nbformat":4,"nbformat_minor":5,"metadata":{"kernelspec":{"name":"python"}},"cells":[{"cell_type":"markdown","metadata":{},"source":["# Gap starter text"]}]}
                    """#.utf8),
                on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "gap_reset_setup", title: "Reset Lab", isOpen: true, on: app)
            let workingCopy = try arSeedStudentWorkingCopy(
                setupID: "gap_reset_setup", userID: studentID,
                bytes: Data(#"{"nbformat":4,"nbformat_minor":5,"metadata":{},"cells":[]}"#.utf8),
                on: app)

            let response = try await post(
                StudentCoursePaths.reset(
                    courseCode: "TEST101", urlToken: staffed.urlToken,
                    assignmentID: assignment.publicID),
                form: [:], cookie: staffed.cookie, on: app)
            #expect(response.status == .seeOther)
            #expect(
                response.headers.first(name: .location)
                    == StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: staffed.urlToken))

            let written = try String(contentsOf: URL(fileURLWithPath: workingCopy), encoding: .utf8)
            #expect(written.contains("Gap starter text"))
        }
    }

    @Test func theNotebookResetIsRefusedWhenTheSetupHasNoStarter() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_nostarter_student", on: app)
            try await arInsertSetup(id: "gap_nostarter_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "gap_nostarter_setup", title: "No Starter Lab", isOpen: true, on: app)

            let response = try await post(
                StudentCoursePaths.reset(
                    courseCode: "TEST101", urlToken: staffed.urlToken,
                    assignmentID: assignment.publicID),
                form: [:], cookie: staffed.cookie, on: app)
            #expect(response.status == .badRequest)
        }
    }

    // MARK: - Who may read the per-student page

    @Test func aPerCourseStudentCannotReadAnotherStudentsPage() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_victim_student", on: app)
            try await arInsertSetup(id: "gap_victim_setup", on: app)
            try await arInsertAssignment(
                testSetupID: "gap_victim_setup", title: "Private Lab", isOpen: true, on: app)
            let studentCookie = try await arLoginAsStudent(on: app)
            let peer = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "teststudent").first())
            if try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == (try peer.requireID())).count() == 0
            {
                try await arEnrollStudentInTestCourse(peer, on: app)
            }

            let response = try await getResponse(
                StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: staffed.urlToken),
                cookie: studentCookie, on: app)
            #expect(response.status == .forbidden)
            #expect(!response.body.string.contains("Private Lab"))
        }
    }

    @Test func staffOfAnotherCourseCannotReadThisCoursesStudent() async throws {
        try await withAssignmentRoutesApp { app in
            let staffed = try await staffedCourse(studentName: "gap_foreign_student", on: app)
            try await arInsertSetup(id: "gap_foreign_setup", on: app)
            try await arInsertAssignment(
                testSetupID: "gap_foreign_setup", title: "Foreign Lab", isOpen: true, on: app)
            _ = try await makeTestCourse(on: app, code: "GAPSTAFF", name: "Other", mode: .closed)
            let foreignCookie = try await loginAsCourseInstructor(
                username: "gap_foreign_instructor", courseCode: "GAPSTAFF", on: app)

            let response = try await getResponse(
                StudentCoursePaths.submissions(courseCode: "TEST101", urlToken: staffed.urlToken),
                cookie: foreignCookie, on: app)
            #expect(response.status == .forbidden)
            #expect(!response.body.string.contains("Foreign Lab"))
        }
    }
}
