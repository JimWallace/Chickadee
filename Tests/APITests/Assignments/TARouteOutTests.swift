// Tests/APITests/Assignments/TARouteOutTests.swift
//
// Creating an assignment is an instructor action, so a TA is not offered the
// new-assignment form. A TA still has a route out where the form was:
//
//   - on an empty course, the staff dashboard keeps the "+ Add" menu, whose
//     material items a TA may use;
//   - the LMS content picker links to the form only for a launching user who
//     may create an assignment, and tells a TA who creates them.

import Core
import Elementary
import Fluent
import Foundation
import Testing
import Vapor
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class TARouteOutTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-ta-route-out")
    }

    /// The session cookie of `username`, enrolled in `courseID` at `role` (their
    /// only course, so it is their active one).
    private func signIn(_ username: String, role: CourseRole, courseID: UUID) async throws -> String {
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let user = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: try user.requireID(), courseID: courseID, role: role).save(on: app.db)
        return cookie
    }

    @Test func aTAOnAnEmptyCourseKeepsTheMaterialItems() async throws {
        try await withApp(app) { _ in
            let courseID = try await makeTestCourse(on: app, code: "ROEMPTY", mode: .closed).requireID()
            let cookie = try await signIn("ro_ta", role: .ta, courseID: courseID)

            let html = try await getHTML("/instructor", cookie: cookie, on: app)
            #expect(html.contains("No assignments yet. A course instructor creates them."))
            #expect(html.contains("data-add-kind=\"slides\""))
            #expect(!html.contains("href=\"/instructor/new\""))
        }
    }

    @Test(arguments: [true, false])
    func theLMSPickerOffersTheFormOnlyToACreator(canCreate: Bool) async throws {
        try await withApp(app) { _ in
            let html = LTIDeepLinkPage(
                page: ElementaryPageFixtures.page(), ticket: "t", courseCode: "ROLTI", acceptMultiple: true,
                assignments: [], error: nil, canCreateAssignment: canCreate
            ).render()
            #expect(html.contains("href=\"/instructor/new\"") == canCreate)
            #expect(html.contains("A course instructor creates assignments.") == !canCreate)
        }
    }
}
