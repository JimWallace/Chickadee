// Tests/APITests/LTI/LTIPlatformScopeTests.swift
//
// What a launch may change is limited to what its platform owns
// (docs/compliance/lti-audit-2026-10.md). L-1: a service URL on a host the
// admin did not register for the course's platform is not stored. L-3: a
// context binds by LEARN org unit only while one platform is enabled, and
// the binding is audited.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LTIPlatformScopeTests {
    let app: Application

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-platform-scope")
    }

    @discardableResult
    private func makePlatform(
        issuer: String = "https://lms.example.edu", enabled: Bool = true
    ) async throws
        -> APILTIPlatform
    {
        let platform = APILTIPlatform(
            issuer: issuer, clientID: "client", deploymentIDs: ["d"],
            authLoginURL: "\(issuer)/auth", accessTokenURL: "\(issuer)/token",
            jwksURL: "\(issuer)/jwks", displayName: "LMS", enabled: enabled)
        try await platform.save(on: app.db)
        return platform
    }

    private func makeCourse(orgUnit: String? = nil) async throws -> APICourse {
        let course = try await makeTestCourse(on: app, code: "CS135")
        course.brightspaceOrgUnitID = orgUnit
        try await course.save(on: app.db)
        return course
    }

    private static func launch(ags: String?, nrps: String?) -> LTIValidatedLaunch {
        var launch = LTIValidatedLaunch(
            messageType: .resourceLink, subject: "subject-1", nonce: "nonce",
            deploymentID: LTITestPlatform.deploymentID,
            courseRole: .student, context: LTILaunchClaims.Context(id: "context-1", label: nil, title: nil),
            resourceLink: LTILaunchClaims.ResourceLink(id: "link-1", title: nil), name: nil, email: nil,
            custom: [:])
        launch.agsEndpoint = ags.map { LTIAGSEndpoint(scope: LTIServiceClient.agsScopes, lineItems: $0, lineItem: nil) }
        launch.nrpsEndpoint = nrps.map { LTINRPSEndpoint(contextMembershipsURL: $0, serviceVersions: ["2.0"]) }
        return launch
    }

    // MARK: - L-1: service URLs from a launch

    @Test func aLaunchStoresServiceURLsOnThePlatformHost() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform()
            let course = try await makeCourse()
            try await LTICourseBinding.bind(course, platformID: try platform.requireID(), contextID: "c", on: app.db)
            let items = "https://lms.example.edu/api/lti/courses/7/line_items"
            let members = "https://lms.example.edu/api/lti/courses/7/names_and_roles"

            try await LTIRoutes.recordLaunchServices(
                launch: Self.launch(ags: items, nrps: members), course: course, userID: UUID(), on: app.db)

            let stored = try #require(try await APICourse.find(course.id, on: app.db))
            #expect(stored.ltiLineItemsURL == items)
            #expect(stored.ltiMembershipsURL == members)
        }
    }

    @Test func aLaunchIgnoresServiceURLsOnAnotherHost() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform()
            let course = try await makeCourse()
            try await LTICourseBinding.bind(course, platformID: try platform.requireID(), contextID: "c", on: app.db)
            course.ltiLineItemsURL = "https://lms.example.edu/line_items"
            course.ltiMembershipsURL = "https://lms.example.edu/members"
            try await course.save(on: app.db)

            try await LTIRoutes.recordLaunchServices(
                launch: Self.launch(ags: "https://evil.example/line_items", nrps: "https://evil.example/members"),
                course: course, userID: UUID(), on: app.db)

            let stored = try #require(try await APICourse.find(course.id, on: app.db))
            #expect(stored.ltiLineItemsURL == "https://lms.example.edu/line_items")
            #expect(stored.ltiMembershipsURL == "https://lms.example.edu/members")
        }
    }

    // MARK: - L-3: binding by org unit

    @Test func withOnePlatformAContextBindsByOrgUnit() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform()
            let course = try await makeCourse(orgUnit: "6606")

            let match = try #require(
                try await LTICourseBinding.course(
                    platformID: try platform.requireID(), contextID: "6606", on: app.db))

            #expect(match.course.id == course.id)
            #expect(match.boundByOrgUnit)
            let again = try await LTICourseBinding.course(
                platformID: try platform.requireID(), contextID: "6606", on: app.db)
            #expect(again?.boundByOrgUnit == false)
        }
    }

    @Test func withTwoPlatformsAContextDoesNotBindByOrgUnit() async throws {
        try await withApp(app) { _ in
            try await makePlatform(issuer: "https://learn.example.edu")
            let other = try await makePlatform(issuer: "https://moodle.example.edu")
            let course = try await makeCourse(orgUnit: "6606")

            let match = try await LTICourseBinding.course(
                platformID: try other.requireID(), contextID: "6606", on: app.db)

            #expect(match == nil)
            let stored = try #require(try await APICourse.find(course.id, on: app.db))
            #expect(stored.ltiPlatformID == nil)
            #expect(stored.ltiContextID == nil)
        }
    }

    @Test func aDisabledPlatformDoesNotCount() async throws {
        try await withApp(app) { _ in
            let platform = try await makePlatform(issuer: "https://learn.example.edu")
            try await makePlatform(issuer: "https://moodle.example.edu", enabled: false)
            let course = try await makeCourse(orgUnit: "6606")

            let match = try await LTICourseBinding.course(
                platformID: try platform.requireID(), contextID: "6606", on: app.db)

            #expect(match?.course.id == course.id)
            #expect(match?.boundByOrgUnit == true)
        }
    }

    @Test func aLaunchThatBindsByOrgUnitIsAudited() async throws {
        let platform = try await LTITestPlatform.make()
        defer { platform.cleanUp() }
        try await withApp(app) { app in
            try await platform.install(on: app)
            let course = try await makeCourse(orgUnit: "context-1")
            let login = try await startLogin()
            let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))

            try await app.asyncTest(
                .POST, "/lti/launch",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: login.cookie)
                    try req.content.encode(["id_token": token, "state": login.state], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                })

            let entry = try #require(
                try await APIAuditLogEntry.query(on: app.db)
                    .filter(\.$action == AuditAction.ltiCourseBound.rawValue)
                    .first())
            #expect(entry.targetID == course.id?.uuidString)
            #expect(entry.actorUsername == "lti")
            #expect(entry.metadataDictionary["method"] == "org_unit")
        }
    }

    /// Runs `/lti/login` as the platform would and returns what the launch needs.
    private func startLogin() async throws -> (state: String, nonce: String, cookie: String) {
        var result: (state: String, nonce: String, cookie: String)?
        let query =
            "iss=\(LTITestPlatform.issuer)&login_hint=hint-1&target_link_uri=http://localhost/lti/launch"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        try await app.asyncTest(.GET, "/lti/login?\(query)") { res in
            let location = try #require(res.headers.first(name: .location))
            let items = try #require(URLComponents(string: location)?.queryItems)
            let state = try #require(items.first { $0.name == "state" }?.value)
            let nonce = try #require(items.first { $0.name == "nonce" }?.value)
            let cookie = try #require(res.headers.setCookie?[LTIRoutes.stateCookieName])
            result = (state, nonce, "\(LTIRoutes.stateCookieName)=\(cookie.string)")
        }
        return try #require(result)
    }
}
