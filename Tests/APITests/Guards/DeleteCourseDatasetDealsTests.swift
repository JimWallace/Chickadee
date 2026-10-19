// Tests/APITests/Guards/DeleteCourseDatasetDealsTests.swift
//
// Deleting a course removes the deal numbers of its assignments. A deal maps
// a student to a part of a partition dataset, so `deleteCourse` deletes it
// explicitly, as it does a class composite's slots, and not only by the
// cascade (docs/datasets-course-library.md §4.11).

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct DeleteCourseDatasetDealsTests {

    @Test func deletingACourseRemovesItsDealNumbers() async throws {
        let app = try await makeTestApp(prefix: "chickadee-delete-deals")
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("delete_deals_admin", on: app)
            let student = try await makeTestUser(on: app, username: "deals_student", role: "student")
            let course = try await makeTestCourse(on: app, code: "DEAL101", name: "Deals", archived: true)
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_deal_delete", courseID: courseID)
            let assignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_deal_delete", courseID: courseID)
            try await APIDatasetDeal(
                assignmentID: try assignment.requireID(), userID: try student.requireID(), dealNumber: 0
            ).create(on: app.db)
            // A deal in another course stays.
            let other = try await makeTestCourse(on: app, code: "DEAL202", name: "Other")
            try await makeTestSetup(on: app, id: "setup_deal_other", courseID: try other.requireID())
            let otherAssignment = try await makeTestAssignment(
                on: app, testSetupID: "setup_deal_other", courseID: try other.requireID())
            try await APIDatasetDeal(
                assignmentID: try otherAssignment.requireID(), userID: try student.requireID(), dealNumber: 0
            ).create(on: app.db)

            let path = "/admin/courses/\(courseID.uuidString)"
            let (token, boundCookie) = try await csrfFields(for: path, cookie: cookie, on: app)
            try await app.asyncTest(
                .POST, "\(path)/delete",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            #expect(try await APICourse.find(courseID, on: app.db) == nil)
            let remaining = try await APIDatasetDeal.query(on: app.db).all().map(\.assignmentID)
            #expect(remaining == [try otherAssignment.requireID()])
        }
    }
}
