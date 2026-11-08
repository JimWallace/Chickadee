// Tests/APITests/MCP/MCPCourseStaffReadGateTests.swift
//
// MCP eligibility only says "staff in some course". A TA in course A who is a
// student in course B passed it, and the read gate (`authorizeCourseAccess`)
// checked only the enrollment in B, so `get_solution` and `get_suite` handed
// B's answer key and secret tests to one of B's students. The read gate now
// needs `.ta` or above in the target course for a human who is not an admin.

import Core
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(3)))
struct MCPCourseStaffReadGateTests {

    /// Seeds course A, where `subject` holds `roleInA`, and course B, where it
    /// holds `roleInB`. Returns course B's id.
    private func seed(
        on app: Application, subject: String, userRole: String, roleInA: CourseRole?, roleInB: CourseRole
    ) async throws -> UUID {
        let courseA = try await makeTestCourse(on: app, code: "CS100", name: "Intro")
        let courseB = try await makeTestCourse(on: app, code: "CS246", name: "OOP")
        let user = try await makeTestUser(on: app, username: subject, role: userRole)
        let userID = try user.requireID()
        if let roleInA {
            try await APICourseEnrollment(userID: userID, courseID: try courseA.requireID(), role: roleInA)
                .save(on: app.db)
        }
        try await APICourseEnrollment(userID: userID, courseID: try courseB.requireID(), role: roleInB)
            .save(on: app.db)
        return try courseB.requireID()
    }

    private func isRefused(on app: Application, subject: String, courseID: UUID) async throws -> Bool {
        let context = ToolContext(request: makeTestRequest(on: app), subject: subject, grantedScopes: [.read])
        do {
            try await context.authorizeCourseAccess(courseID)
            return false
        } catch let error as MCPToolError {
            if case .notAuthorized = error { return true }
            throw error
        }
    }

    @Test func aTAElsewhereWhoIsAStudentHereIsRefused() async throws {
        try await withTestApp { app in
            let courseB = try await seed(
                on: app, subject: "ta_elsewhere", userRole: "student", roleInA: .ta, roleInB: .student)
            #expect(try await isRefused(on: app, subject: "ta_elsewhere", courseID: courseB))
        }
    }

    @Test func aTAInTheCourseIsAllowed() async throws {
        try await withTestApp { app in
            let courseB = try await seed(
                on: app, subject: "ta_here", userRole: "student", roleInA: nil, roleInB: .ta)
            #expect(try await !isRefused(on: app, subject: "ta_here", courseID: courseB))
        }
    }

    @Test func anAdminEnrolledAsAStudentIsAllowed() async throws {
        try await withTestApp { app in
            let courseB = try await seed(
                on: app, subject: "admin_student", userRole: "admin", roleInA: nil, roleInB: .student)
            #expect(try await !isRefused(on: app, subject: "admin_student", courseID: courseB))
        }
    }
}

/// `clientIPAddress` keys the login and MCP OAuth rate limits. nginx appends
/// the peer it saw after whatever the client sent, so only the last
/// `X-Forwarded-For` entry is trustworthy.
@Suite struct ClientIPAddressForwardedForTests {

    @Test(arguments: [
        ("203.0.113.9", "203.0.113.9"),
        ("198.51.100.1, 203.0.113.9", "203.0.113.9"),
        ("10.0.0.1,198.51.100.1 , 203.0.113.9", "203.0.113.9"),
    ])
    func keysOnTheLastForwardedEntry(header: String, expected: String) async throws {
        try await withTestApp { app in
            let request = makeTestRequest(on: app, headers: ["X-Forwarded-For": header])
            #expect(clientIPAddress(from: request, trustForwardedFor: true) == expected)
        }
    }
}
