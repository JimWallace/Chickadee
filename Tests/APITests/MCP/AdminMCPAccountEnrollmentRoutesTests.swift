// Tests/APITests/MCP/AdminMCPAccountEnrollmentRoutesTests.swift
//
// `POST /admin/mcp/accounts/:userID/enroll` and `.../unenroll`.
//
// An MCP service account reaches exactly the courses it is enrolled in, for
// every role (Sources/APIServer/MCP/CLAUDE.md). These two routes are therefore
// how an admin widens or narrows what an agent can touch, and each is pinned
// for what it does and for whom it refuses.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2)))
final class AdminMCPAccountEnrollmentRoutesTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-mcp-enroll")
    }

    private func makeAgent(_ username: String = "authoring-agent") async throws -> APIUser {
        let agent = APIUser(username: username, passwordHash: "!unusable", role: UserRole.mcp.rawValue)
        try await agent.save(on: app.db)
        return agent
    }

    private func post(
        _ path: String, courseID: String, cookie: String
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .ok
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(["courseID": courseID, "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    private func enrollmentCount(_ agent: APIUser, courseID: UUID) async throws -> Int {
        try await APICourseEnrollment.query(on: app.db)
            .filter(\.$userID == agent.requireID())
            .filter(\.$course.$id == courseID)
            .count()
    }

    @Test func enrollingAnAgentAddsOneStudentEnrollment() async throws {
        try await withApp(app) { _ in
            let agent = try await makeAgent()
            let courseID = try await makeTestCourse(on: app, code: "MCP101").requireID()
            let cookie = try await loginAsAdmin("mcp_admin", on: app)
            let path = "/admin/mcp/accounts/\(try agent.requireID())/enroll"

            let first = try await post(path, courseID: courseID.uuidString, cookie: cookie)
            _ = try await post(path, courseID: courseID.uuidString, cookie: cookie)

            #expect(first.location == "/admin/mcp")
            let rows = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$userID == agent.requireID()).all()
            #expect(rows.count == 1, "enrolling twice keeps one row")
            #expect(rows.first?.role == .student, "an agent never gains staff rights by enrollment")
        }
    }

    @Test(arguments: ["", "not-a-uuid", UUID().uuidString])
    func enrollingIntoACourseThatDoesNotExistIsRefused(courseID: String) async throws {
        try await withApp(app) { _ in
            let agent = try await makeAgent()
            let cookie = try await loginAsAdmin("mcp_admin", on: app)

            let response = try await post(
                "/admin/mcp/accounts/\(try agent.requireID())/enroll", courseID: courseID, cookie: cookie)

            #expect(response.location == "/admin/mcp?error=enroll_failed")
            #expect(
                try await APICourseEnrollment.query(on: app.db).filter(\.$userID == agent.requireID()).count() == 0)
        }
    }

    @Test func unenrollingAnAgentRemovesOnlyThatCourse() async throws {
        try await withApp(app) { _ in
            let agent = try await makeAgent()
            let kept = try await makeTestCourse(on: app, code: "KEEP1").requireID()
            let dropped = try await makeTestCourse(on: app, code: "DROP1").requireID()
            for courseID in [kept, dropped] {
                try await APICourseEnrollment(userID: try agent.requireID(), courseID: courseID, role: .student)
                    .save(on: app.db)
            }
            let cookie = try await loginAsAdmin("mcp_admin", on: app)

            let response = try await post(
                "/admin/mcp/accounts/\(try agent.requireID())/unenroll", courseID: dropped.uuidString, cookie: cookie)

            #expect(response.location == "/admin/mcp")
            #expect(try await enrollmentCount(agent, courseID: dropped) == 0)
            #expect(try await enrollmentCount(agent, courseID: kept) == 1)
        }
    }

    @Test(arguments: ["enroll", "unenroll"])
    func aHumanAccountCannotBeManagedThroughTheAgentRoutes(action: String) async throws {
        try await withApp(app) { _ in
            let human = try await makeTestUser(on: app, username: "a_person")
            let courseID = try await makeTestCourse(on: app, code: "HUM101").requireID()
            try await APICourseEnrollment(userID: try human.requireID(), courseID: courseID, role: .student)
                .save(on: app.db)
            let cookie = try await loginAsAdmin("mcp_admin", on: app)

            let response = try await post(
                "/admin/mcp/accounts/\(try human.requireID())/\(action)", courseID: courseID.uuidString, cookie: cookie)

            #expect(response.status == .notFound)
            #expect(try await enrollmentCount(human, courseID: courseID) == 1)
        }
    }

    @Test(arguments: ["enroll", "unenroll"])
    func aNonAdminIsRefusedAndChangesNothing(action: String) async throws {
        try await withApp(app) { _ in
            let agent = try await makeAgent()
            let enrolled = try await makeTestCourse(on: app, code: "ENR101").requireID()
            let other = try await makeTestCourse(on: app, code: "OTH101").requireID()
            try await APICourseEnrollment(userID: try agent.requireID(), courseID: enrolled, role: .student)
                .save(on: app.db)
            let cookie = try await loginAsStudent("not_admin", on: app)
            let target = action == "enroll" ? other : enrolled

            let response = try await post(
                "/admin/mcp/accounts/\(try agent.requireID())/\(action)", courseID: target.uuidString, cookie: cookie)

            #expect(response.status == .forbidden)
            #expect(try await enrollmentCount(agent, courseID: enrolled) == 1)
            #expect(try await enrollmentCount(agent, courseID: other) == 0)
        }
    }
}
