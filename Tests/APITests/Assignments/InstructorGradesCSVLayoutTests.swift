// Tests/APITests/Assignments/InstructorGradesCSVLayoutTests.swift
//
// GET /instructor/grades.csv (`InstructorDashboardRoutes+GradesCSV.swift`):
// the exact columns, their order by course section, CSV escaping, the
// response headers, and whose rows the export holds. An instructor of
// another course sees none of this course; an admin with no active course
// gets every course's students; a TA of the course may read it.
// `GradeOverridesTests` pins the best-grade and override arithmetic.

import Core
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class InstructorGradesCSVLayoutTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-grades-csv-layout")
    }

    private static let tenPointManifest = """
        {"schemaVersion":1,"requiredFiles":[],"testSuites":\
        [{"tier":"public","script":"t.sh","points":10}],"timeLimitSeconds":10}
        """

    /// `username`, enrolled in `courseID` at `role` as their only course,
    /// signed in. Returns the session cookie.
    private func signIn(_ username: String, role: CourseRole, courseID: UUID) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "student", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        return cookie
    }

    private func enrolledUser(
        _ username: String, studentID: String? = nil, role: CourseRole = .student, in courseID: UUID
    ) async throws -> UUID {
        let user = try await makeTestStudent(on: app, username: username)
        user.studentID = studentID
        try await user.save(on: app.db)
        let id = try user.requireID()
        try await APICourseEnrollment(userID: id, courseID: courseID, role: role).save(on: app.db)
        return id
    }

    private func assignment(
        _ setupID: String, title: String, courseID: UUID, section: APICourseSection? = nil, order: Int
    ) async throws {
        try await makeTestSetup(on: app, id: setupID, courseID: courseID, manifest: Self.tenPointManifest)
        let assignment = try await makeTestAssignment(
            on: app, testSetupID: setupID, courseID: courseID, title: title)
        assignment.sectionID = try section?.requireID()
        assignment.sortOrder = order
        try await assignment.save(on: app.db)
    }

    private func section(_ name: String, order: Int, courseID: UUID) async throws -> APICourseSection {
        let section = APICourseSection(name: name, sortOrder: order, courseID: courseID)
        try await section.save(on: app.db)
        return section
    }

    private func override(_ percent: Int, setupID: String, userID: UUID) async throws {
        try await APIGradeOverride(testSetupID: setupID, userID: userID, overridePercent: percent).save(on: app.db)
    }

    private func export(cookie: String) async throws -> TestResponse {
        try await getResponse("/instructor/grades.csv", cookie: cookie, on: app)
    }

    // MARK: - Layout

    @Test func theColumnsFollowTheSectionOrderAndEveryCellIsEscaped() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "GCSV1", mode: .closed).requireID()
            let cookie = try await signIn("gcsv_inst", role: .instructor, courseID: courseID)
            // The section made first sorts second, so the order is the
            // section's display order and not the row order.
            let later = try await section("Later", order: 2, courseID: courseID)
            let earlier = try await section("Earlier", order: 1, courseID: courseID)
            try await assignment("gcsv_lab", title: #"Lab, "one""#, courseID: courseID, section: later, order: 1)
            try await assignment("gcsv_quiz", title: "Quiz", courseID: courseID, section: earlier, order: 2)
            try await assignment("gcsv_intro", title: "Intro", courseID: courseID, section: earlier, order: 1)
            try await assignment("gcsv_extra", title: "Extra", courseID: courseID, order: 1)

            let zed = try await enrolledUser("gcsv_zed", studentID: "20001234", in: courseID)
            let amy = try await enrolledUser("gcsv_amy", in: courseID)
            _ = try await enrolledUser("gcsv_ta", studentID: "99990000", role: .ta, in: courseID)

            try await override(75, setupID: "gcsv_intro", userID: zed)
            try await override(100, setupID: "gcsv_extra", userID: amy)
            try await makeTestSubmission(on: app, id: "gcsv_sub_zed", setupID: "gcsv_lab", userID: zed)
            try await makeTestResult(
                on: app, submissionID: "gcsv_sub_zed",
                collectionJSON: #"{"earnedPoints":4,"totalPoints":10,"passCount":0,"totalTests":1}"#)

            let response = try await export(cookie: cookie)
            #expect(response.status == .ok)
            #expect(response.headers.first(name: .contentType) == "text/csv; charset=utf-8")
            let disposition = try #require(response.headers.first(name: .contentDisposition))
            #expect(disposition.wholeMatch(of: #/attachment; filename="grades-\d+\.csv"/#) != nil, "\(disposition)")

            let expected = """
                OrgDefinedId,Username,Intro Points Grade,Quiz Points Grade,"Lab, ""one"" Points Grade",\
                Extra Points Grade,End-of-Line Indicator
                ,#gcsv_amy,,,,10.0,#
                20001234,#gcsv_zed,7.5,,4.0,,#

                """
            #expect(response.body.string == expected)
        }
    }

    @Test func aCourseWithNoStudentsExportsTheHeaderAlone() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "GCSV2", mode: .closed).requireID()
            let cookie = try await signIn("gcsv_empty", role: .instructor, courseID: courseID)
            try await assignment("gcsv_only", title: "Only", courseID: courseID, order: 1)
            let response = try await export(cookie: cookie)
            #expect(response.status == .ok)
            #expect(response.body.string == "OrgDefinedId,Username,Only Points Grade,End-of-Line Indicator\n")
        }
    }

    // MARK: - Whose rows

    @Test func anInstructorOfAnotherCourseExportsOnlyTheirOwnCourse() async throws {
        try await withApp(app) { app in
            let courseA = try await makeTestCourse(on: app, code: "GCSV3A", mode: .closed).requireID()
            let courseB = try await makeTestCourse(on: app, code: "GCSV3B", mode: .closed).requireID()
            try await assignment("gcsv_a_lab", title: "Course A Lab", courseID: courseA, order: 1)
            let aStudent = try await enrolledUser("gcsv_a_student", studentID: "11110000", in: courseA)
            try await override(90, setupID: "gcsv_a_lab", userID: aStudent)
            try await assignment("gcsv_b_lab", title: "Course B Lab", courseID: courseB, order: 1)
            _ = try await enrolledUser("gcsv_b_student", in: courseB)

            let cookie = try await signIn("gcsv_b_inst", role: .instructor, courseID: courseB)
            let response = try await export(cookie: cookie)
            #expect(response.status == .ok)
            #expect(
                response.body.string == """
                    OrgDefinedId,Username,Course B Lab Points Grade,End-of-Line Indicator
                    ,#gcsv_b_student,,#

                    """)
        }
    }

    @Test func aTAOfTheCourseMayExportIt() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "GCSV4", mode: .closed).requireID()
            try await assignment("gcsv_ta_lab", title: "Lab", courseID: courseID, order: 1)
            let student = try await enrolledUser("gcsv_ta_student", studentID: "33330000", in: courseID)
            try await override(50, setupID: "gcsv_ta_lab", userID: student)
            let cookie = try await signIn("gcsv_ta_reader", role: .ta, courseID: courseID)
            let response = try await export(cookie: cookie)
            #expect(response.status == .ok)
            #expect(response.body.string.contains("33330000,#gcsv_ta_student,5.0,#"))
            #expect(!response.body.string.contains("gcsv_ta_reader"), "staff are not rows")
        }
    }

    @Test func aStudentMayNotExportTheCourse() async throws {
        try await withApp(app) { app in
            let courseID = try await makeTestCourse(on: app, code: "GCSV5", mode: .closed).requireID()
            let cookie = try await signIn("gcsv_nosy", role: .student, courseID: courseID)
            let response = try await export(cookie: cookie)
            #expect(response.status == .forbidden)
            #expect(!response.body.string.contains("OrgDefinedId"))
        }
    }

    @Test func anAdminWithNoActiveCourseExportsEveryCoursesStudents() async throws {
        try await withApp(app) { app in
            let courseA = try await makeTestCourse(on: app, code: "GCSV6A", mode: .closed).requireID()
            let courseB = try await makeTestCourse(on: app, code: "GCSV6B", archived: true, mode: .closed).requireID()
            try await assignment("gcsv_all_a", title: "First", courseID: courseA, order: 1)
            try await assignment("gcsv_all_b", title: "Second", courseID: courseB, order: 2)
            let both = try await enrolledUser("gcsv_both", studentID: "44440000", in: courseA)
            try await APICourseEnrollment(userID: both, courseID: courseB, role: .student).save(on: app.db)
            let onlyB = try await enrolledUser("gcsv_only_b", in: courseB)
            _ = try await enrolledUser("gcsv_staff", role: .instructor, in: courseA)
            try await override(100, setupID: "gcsv_all_b", userID: onlyB)

            // Not enrolled anywhere and no course enrols automatically, so the
            // admin has no active course.
            let cookie = try await loginAsAdmin("gcsv_admin", on: app)
            let response = try await export(cookie: cookie)
            #expect(response.status == .ok)
            #expect(
                response.body.string == """
                    OrgDefinedId,Username,First Points Grade,Second Points Grade,End-of-Line Indicator
                    44440000,#gcsv_both,,,#
                    ,#gcsv_only_b,,10.0,#

                    """)
        }
    }
}
