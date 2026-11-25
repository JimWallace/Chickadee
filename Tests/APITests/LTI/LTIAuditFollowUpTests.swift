// Tests/APITests/LTI/LTIAuditFollowUpTests.swift
//
// Findings L-7 and L-8 of docs/compliance/lti-audit-2026-10.md:
// - `POST /lti/deep-link/bind` with no enabled platform is refused before the
//   tool key loads, so it never writes `.lti-tool-key` (compatibility rule 1);
// - registering or editing a platform records its "Trust username" switch,
//   before and after an edit;
// - a launch that enrolls a user records `lti.enrolled` with the role the LMS
//   claimed, once, and a later launch into the same course records nothing.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class LTIAuditFollowUpTests {
    let app: Application
    let platform: LTITestPlatform
    let keyDirectory: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-audit")
        platform = try await LTITestPlatform.make()
        keyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        app.ltiToolKeyFilePath = keyDirectory.appendingPathComponent(".lti-tool-key").path
    }

    deinit {
        platform.cleanUp()
        try? FileManager.default.removeItem(at: keyDirectory)
    }

    private func entries(_ action: AuditAction) async throws -> [APIAuditLogEntry] {
        try await APIAuditLogEntry.query(on: app.db).filter(\.$action == action.rawValue).all()
    }

    // MARK: - L-7

    @Test func deepLinkBindWithoutAPlatformIsRefusedAndWritesNoKey() async throws {
        try await withApp(app) { app in
            try await app.asyncTest(
                .POST, "/lti/deep-link/bind",
                beforeRequest: { req in
                    try req.content.encode(
                        ["token": "not-a-token", "courseID": UUID().uuidString], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
            #expect(!FileManager.default.fileExists(atPath: app.ltiToolKeyFilePath))
        }
    }

    @Test func deepLinkBindWithOnlyADisabledPlatformWritesNoKey() async throws {
        try await withApp(app) { app in
            _ = try await platform.install(on: app, enabled: false)
            try await app.asyncTest(
                .POST, "/lti/deep-link/bind",
                beforeRequest: { req in
                    try req.content.encode(["token": "not-a-token"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
            #expect(!FileManager.default.fileExists(atPath: app.ltiToolKeyFilePath))
        }
    }

    // MARK: - L-8: Trust username

    static let form: [String: String] = [
        "displayName": "UW LEARN",
        "issuer": "https://learn.example.edu",
        "clientID": "client-1",
        "deploymentIDs": "deployment-1",
        "authLoginURL": "https://learn.example.edu/d2l/lti/authenticate",
        "accessTokenURL": "https://auth.example.edu/core/connect/token",
        "jwksURL": "https://learn.example.edu/d2l/.well-known/jwks",
    ]

    private func adminPost(_ path: String, _ fields: [String: String], cookie: String) async throws {
        let (token, boundCookie) = try await csrfFields(for: "/admin/lti", cookie: cookie, on: app)
        var body = fields
        body["_csrf"] = token
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                try req.content.encode(body, as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
            })
    }

    @Test func trustUsernameIsRecordedOnRegisterAndOnEachEdit() async throws {
        try await withApp(app) { app in
            let cookie = try await loginAsAdmin("lti_audit_admin", on: app)
            try await adminPost("/admin/lti/platforms", Self.form, cookie: cookie)
            let registered = try #require(try await entries(.ltiPlatformRegistered).first)
            #expect(registered.metadataDictionary["trust_username"] == "false")

            let id = try #require(try await APILTIPlatform.query(on: app.db).first()).requireID()
            var trusted = Self.form
            trusted["trustUsername"] = "true"
            try await adminPost("/admin/lti/platforms/\(id)", trusted, cookie: cookie)
            try await adminPost("/admin/lti/platforms/\(id)", Self.form, cookie: cookie)

            let updates = try await entries(.ltiPlatformUpdated).map(\.metadataDictionary)
            #expect(updates.count == 2)
            let turnedOn = updates.first { $0["trust_username"] == "true" }
            let turnedOff = updates.first { $0["trust_username"] == "false" }
            #expect(turnedOn?["trust_username_before"] == "false")
            #expect(turnedOff?["trust_username_before"] == "true")
        }
    }

    // MARK: - L-8: Launch enrollment

    private struct Login {
        let state: String
        let nonce: String
        let cookie: String
    }

    private func login() async throws -> Login {
        var result: Login?
        let query =
            "iss=\(LTITestPlatform.issuer)&login_hint=hint-1&target_link_uri=http://localhost/lti/launch"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        try await app.asyncTest(.GET, "/lti/login?\(query)") { res in
            let location = try #require(res.headers.first(name: .location))
            let items = (URLComponents(string: location)?.queryItems ?? [])
                .reduce(into: [String: String]()) { $0[$1.name] = $1.value }
            let cookie = try #require(res.headers.setCookie?[LTIRoutes.stateCookieName])
            result = Login(
                state: try #require(items["state"]), nonce: try #require(items["nonce"]),
                cookie: "\(LTIRoutes.stateCookieName)=\(cookie.string)")
        }
        return try #require(result)
    }

    private func launch(roles: [String]) async throws {
        let login = try await login()
        let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce, roles: roles))
        try await app.asyncTest(
            .POST, "/lti/launch",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: login.cookie)
                try req.content.encode(["id_token": token, "state": login.state], as: .urlEncodedForm)
            },
            afterResponse: { res in
                #expect(res.status == .seeOther)
            })
    }

    @Test func aLaunchThatEnrollsRecordsTheClaimedRoleOnce() async throws {
        try await withApp(app) { app in
            let registered = try await platform.install(on: app)
            let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Functional Programs")
            try await LTICourseBinding.bind(
                course, platformID: try registered.requireID(), contextID: "context-1", on: app.db)

            try await launch(roles: [LTITestPlatform.instructor])
            try await launch(roles: [LTITestPlatform.instructor])

            let enrolled = try await entries(.ltiEnrolled)
            #expect(enrolled.count == 1)
            let entry = try #require(enrolled.first)
            #expect(entry.metadataDictionary["role"] == CourseRole.instructor.rawValue)
            #expect(entry.metadataDictionary["course"] == "CS135")
            #expect(entry.courseID == course.id)
        }
    }
}
