// Tests/APITests/Guards/DeleteCourseCoverageTests.swift
//
// Deleting a course removes its class-coverage rows. `class_item_coverage` is
// keyed by test setup with no foreign key, so `deleteCourse` must delete it
// explicitly, as it does `class_coverage_runs`
// (docs/collaborative-class-assignments.md).

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) struct DeleteCourseCoverageTests {

    @Test func deletingACourseRemovesItsItemCoverage() async throws {
        let app = try await makeTestApp(prefix: "chickadee-delete-coverage")
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("delete_coverage_admin", on: app)
            let student = try await makeTestUser(on: app, username: "coverage_student", role: "student")
            let course = try await makeTestCourse(on: app, code: "COV101", name: "Coverage", archived: true)
            // Past the 365-day retention window, so deletion is permitted.
            course.archivedAt = Date().addingTimeInterval(-400 * 86_400)
            try await course.save(on: app.db)
            let courseID = try course.requireID()
            try await makeTestSetup(on: app, id: "setup_cov_delete", courseID: courseID)
            try await makeTestAssignment(on: app, testSetupID: "setup_cov_delete", courseID: courseID)
            try await APIClassItemCoverage(
                testSetupID: "setup_cov_delete", item: "variant_1", userID: try student.requireID(),
                submissionID: "sub_cov"
            ).create(on: app.db)
            // A row for another course's setup stays.
            try await APIClassItemCoverage(
                testSetupID: "setup_elsewhere", item: "variant_1", userID: try student.requireID(),
                submissionID: "sub_other"
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
            let remaining = try await APIClassItemCoverage.query(on: app.db).all().map(\.testSetupID)
            #expect(remaining == ["setup_elsewhere"])
        }
    }
}
