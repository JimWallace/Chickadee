// Tests/APITests/EnsureSeededEnrollmentTests.swift

import Fluent
import Testing
import Vapor

@testable import APIServer

@Suite struct EnsureSeededEnrollmentTests {
    @Test func enrollsOnceAndIsIdempotent() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let course = try await makeTestCourse(on: app, code: "CS136", name: "Systems")
            let user = try await makeTestUser(on: app, username: "student1")
            let userID = try user.requireID()
            let courseID = try course.requireID()

            let created = try await ensureSeededEnrollment(userID: userID, courseID: courseID, on: app.db)
            let repeated = try await ensureSeededEnrollment(userID: userID, courseID: courseID, on: app.db)
            #expect(created == true)
            #expect(repeated == false)

            let rows = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == userID)
                .filter(\.$course.$id == courseID)
                .count()
            #expect(rows == 1)
        }
    }
}
