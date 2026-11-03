// Tests/APITests/Courses/StaffPlaceholderRuleTests.swift
//
// #2770: the placeholder rule is the same on the instructor roster's staff
// invite and on the admin course page's staff form. A placeholder account is
// made only where an SSO login can adopt it. Under local sign-in only, both
// doors refuse an unknown username. The dual-mode case stands in for SSO: it
// has the SSO adoption path and still lets a test log in with a password.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(5))) struct StaffPlaceholderRuleTests {

    enum Door: String, CaseIterable, Sendable {
        case instructorRoster
        case adminCoursePage
    }

    /// Posts the staff form for `door` as a fresh actor and returns the
    /// redirect location.
    private func inviteUnknown(
        _ identifier: String, door: Door, courseID: UUID, on app: Application
    ) async throws -> String? {
        let cookie: String
        let path: String
        let formPath: String
        switch door {
        case .instructorRoster:
            cookie = try await loginUser(username: "rule_prof", password: "pw", role: "student", on: app)
            let actor = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "rule_prof").first())
            try await APICourseEnrollment(
                userID: try actor.requireID(), courseID: courseID, role: .instructor
            ).save(on: app.db)
            path = "/courses/\(courseID)/staff"
            formPath = "/"
        case .adminCoursePage:
            cookie = try await loginAsAdmin("rule_admin", on: app)
            path = "/admin/courses/\(courseID)/staff"
            formPath = "/admin/courses/\(courseID)"
        }
        let (token, boundCookie) = try await csrfFields(for: formPath, cookie: cookie, on: app)
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(
                    ["identifier": identifier, "role": "ta", "_csrf": token], as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
                location = res.headers.first(name: .location)
            })
        return location
    }

    @Test(arguments: Door.allCases)
    func localSignIn_refusesPlaceholder(door: Door) async throws {
        let app = try await makeTestApp(prefix: "chickadee-placeholder-local", authMode: .local)
        try await withApp(app) { app in
            #expect(!app.staffPlaceholderAllowed)
            let course = try await makeTestCourse(on: app, code: "RULE1", mode: .closed)
            let courseID = try course.requireID()

            let location = try await inviteUnknown("ghost_ta", door: door, courseID: courseID, on: app)

            #expect(location?.contains("staffError=\(StaffFormError.unknown.rawValue)") == true)
            #expect(try await APIUser.query(on: app.db).filter(\.$username == "ghost_ta").count() == 0)
        }
    }

    @Test(arguments: Door.allCases)
    func ssoSignIn_makesAdoptablePlaceholder(door: Door) async throws {
        let app = try await makeTestApp(prefix: "chickadee-placeholder-sso", authMode: .dual)
        try await withApp(app) { app in
            #expect(app.staffPlaceholderAllowed)
            let course = try await makeTestCourse(on: app, code: "RULE2", mode: .closed)
            let courseID = try course.requireID()

            let location = try await inviteUnknown("new_ta", door: door, courseID: courseID, on: app)

            #expect(location?.contains("staffAdded=1") == true)
            let placeholder = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "new_ta").first())
            #expect(placeholder.passwordHash.isEmpty)
            #expect(placeholder.authProvider == "duo-oidc")
            let enrollment = try await APICourseEnrollment.query(on: app.db)
                .filter(\.$course.$id == courseID)
                .filter(\.$userID == placeholder.requireID())
                .first()
            #expect(enrollment?.role == .ta)
        }
    }
}
