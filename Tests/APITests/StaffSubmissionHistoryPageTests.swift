// Tests/APITests/StaffSubmissionHistoryPageTests.swift
//
// Course staff reach one student's history on one assignment from two places:
// the assignment's roster and the course's per-student view. Both render
// `student-assignment-history.leaf` (#1710), so both name the student the way
// the account page does. They differ in the back link, and only the roster
// route links each submission to its diff: the diff page's History link goes
// back to the roster's copy of this page.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct StaffSubmissionHistoryPageTests {

    private struct Fixture {
        let cookie: String
        let assignmentID: String
        let rosterPath: String
        let coursePath: String
        let courseBackURL: String
    }

    private func fixture(username: String, displayName: String?, on app: Application) async throws -> Fixture {
        let cookie = try await arLoginAsInstructor(on: app)
        let student = try await arInsertStudent(username: username, displayName: displayName, on: app)
        try await arEnrollStudentInTestCourse(student, on: app)
        _ = try await arInsertSetup(id: "hist_setup", on: app)
        let assignment = try await arInsertAssignment(
            testSetupID: "hist_setup", title: "History Lab", isOpen: true, on: app)
        let studentID = try student.requireID()
        _ = try await arInsertSubmission(id: "sub_hist", testSetupID: "hist_setup", userID: studentID, on: app)
        let course = try #require(try await APICourse.find(try await app.testCourseID(), on: app.db))
        let token = try student.requireURLToken()
        return Fixture(
            cookie: cookie,
            assignmentID: assignment.publicID,
            rosterPath: "/instructor/\(assignment.publicID)/students/\(studentID.uuidString)/history",
            coursePath: StudentCoursePaths.assignmentHistory(
                courseCode: course.urlKey, urlToken: token, assignmentID: assignment.publicID),
            courseBackURL: StudentCoursePaths.submissions(courseCode: course.urlKey, urlToken: token))
    }

    @Test func eachRouteNamesTheStudentAndKeepsItsOwnBackLink() async throws {
        try await withAssignmentRoutesApp { app in
            let page = try await fixture(username: "hist_dana", displayName: "Dana Example", on: app)
            let diffPath = "/instructor/\(page.assignmentID)/submissions/sub_hist/diff"

            let roster = try await getHTML(page.rosterPath, cookie: page.cookie, on: app)
            #expect(roster.contains("<strong>Dana Example</strong> (hist_dana)"))
            #expect(roster.contains(#"href="/instructor/\#(page.assignmentID)/submissions">Back to submissions</a>"#))
            #expect(roster.contains(diffPath))

            let course = try await getHTML(page.coursePath, cookie: page.cookie, on: app)
            #expect(course.contains("<strong>Dana Example</strong> (hist_dana)"))
            #expect(course.contains(#"href="\#(page.courseBackURL)">Back to student</a>"#))
            #expect(!course.contains(diffPath), "the course route keeps the reader's way back to the student")

            let diff = try await getHTML(diffPath, cookie: page.cookie, on: app)
            #expect(diff.contains("<strong>Dana Example</strong> (hist_dana)"))
        }
    }

    /// A student with no name on file is named by their username, once.
    @Test func aStudentWithNoNameIsShownOnce() async throws {
        try await withAssignmentRoutesApp { app in
            let page = try await fixture(username: "hist_eli", displayName: nil, on: app)
            for path in [page.rosterPath, page.coursePath] {
                let body = try await getHTML(path, cookie: page.cookie, on: app)
                #expect(body.contains("<strong>hist_eli</strong>"), "\(path)")
                #expect(!body.contains("(hist_eli)"), "\(path)")
            }
        }
    }
}
