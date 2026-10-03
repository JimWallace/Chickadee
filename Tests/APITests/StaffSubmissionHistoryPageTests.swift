// Tests/APITests/StaffSubmissionHistoryPageTests.swift
//
// Course staff reach one student's history on one assignment from two places:
// the assignment's roster and the course's per-student view. Both render
// `student-assignment-history.leaf` (#1710), so both show the student by name
// and username, and both link each submission to its diff against the
// starter. Only the back link differs, because the two pages are reached from
// different places.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized)
struct StaffSubmissionHistoryPageTests {

    @Test func bothRoutesShowTheStudentTheirBackLinkAndTheDiffLink() async throws {
        try await withAssignmentRoutesApp { app in
            let cookie = try await arLoginAsInstructor(on: app)
            let student = try await arInsertStudent(username: "hist_dana", displayName: "Dana Example", on: app)
            try await arEnrollStudentInTestCourse(student, on: app)
            _ = try await arInsertSetup(id: "hist_setup", on: app)
            let assignment = try await arInsertAssignment(
                testSetupID: "hist_setup", title: "History Lab", isOpen: true, on: app)
            let studentID = try student.requireID()
            _ = try await arInsertSubmission(id: "sub_hist", testSetupID: "hist_setup", userID: studentID, on: app)
            let course = try #require(try await APICourse.find(try await app.testCourseID(), on: app.db))
            let token = try student.requireURLToken()

            let pages: [(path: String, backURL: String, backLabel: String)] = [
                (
                    "/instructor/\(assignment.publicID)/students/\(studentID.uuidString)/history",
                    "/instructor/\(assignment.publicID)/submissions", "Back to Assignment Summary"
                ),
                (
                    StudentCoursePaths.assignmentHistory(
                        courseCode: course.urlKey, urlToken: token, assignmentID: assignment.publicID),
                    StudentCoursePaths.submissions(courseCode: course.urlKey, urlToken: token), "Back to student"
                ),
            ]
            for page in pages {
                try await app.asyncTest(
                    .GET, page.path,
                    beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                    afterResponse: { res in
                        #expect(res.status == .ok, "\(page.path)")
                        let html = res.body.string
                        #expect(html.contains("<strong>Dana Example</strong> (hist_dana)"), "\(page.path)")
                        #expect(html.contains(#"href="\#(page.backURL)">\#(page.backLabel)</a>"#), "\(page.path)")
                        #expect(
                            html.contains("/instructor/\(assignment.publicID)/submissions/sub_hist/diff"),
                            "\(page.path)")
                    })
            }
        }
    }
}
