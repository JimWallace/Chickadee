// Tests/APITests/LTI/LTILaunchFlowTests.swift
//
// The LTI 1.3 login and launch end to end (docs/lti-1-3.md slice 2), against
// a stand-in platform that signs with a key the test controls. The happy path
// is asserted first; each refusal then breaks exactly one thing about it.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LTILaunchFlowTests {
    let app: Application
    let platform: LTITestPlatform

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-launch")
        platform = try await LTITestPlatform.make()
    }

    deinit {
        platform.cleanUp()
    }

    struct Login {
        let state: String
        let nonce: String
        let cookie: String
    }

    /// Runs `/lti/login` as the platform would and returns what the launch needs.
    private func login() async throws -> Login {
        var result: Login?
        let query =
            "iss=\(LTITestPlatform.issuer)&login_hint=hint-1&target_link_uri=http://localhost/lti/launch"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        try await app.asyncTest(.GET, "/lti/login?\(query)") { res in
            #expect(res.status == .seeOther)
            let location = try #require(res.headers.first(name: .location))
            let components = try #require(URLComponents(string: location))
            let items = Dictionary(
                (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
            #expect(location.hasPrefix(LTITestPlatform.authLoginURL))
            #expect(items["client_id"] == LTITestPlatform.clientID)
            #expect(items["response_mode"] == "form_post")
            #expect(items["response_type"] == "id_token")
            #expect(items["scope"] == "openid")
            #expect(items["prompt"] == "none")
            #expect(items["login_hint"] == "hint-1")
            #expect(items["redirect_uri"]?.hasSuffix("/lti/launch") == true)
            let state = try #require(items["state"])
            let nonce = try #require(items["nonce"])
            let cookie = try #require(res.headers.setCookie?[LTIRoutes.stateCookieName])
            #expect(cookie.string == state)
            #expect(cookie.isHTTPOnly)
            result = Login(state: state, nonce: nonce, cookie: "\(LTIRoutes.stateCookieName)=\(cookie.string)")
        }
        return try #require(result)
    }

    /// POSTs a launch and hands the response to `check`.
    private func launch(
        idToken: String, state: String, cookie: String?,
        _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.asyncTest(
            .POST, "/lti/launch",
            beforeRequest: { req in
                if let cookie { req.headers.add(name: .cookie, value: cookie) }
                try req.content.encode(["id_token": idToken, "state": state], as: .urlEncodedForm)
            },
            afterResponse: check)
    }

    /// GETs `path` with a session cookie.
    private func get(
        _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: check)
    }

    private func makeCourse(orgUnit: String? = nil) async throws -> APICourse {
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Functional Programs")
        course.brightspaceOrgUnitID = orgUnit
        try await course.save(on: app.db)
        return course
    }

    // MARK: - Happy path

    @Test func studentLaunchSignsInEnrollsAndGoesToTheBoundCourse() async throws {
        try await withApp(app) { app in
            let registered = try await platform.install(on: app)
            let course = try await makeCourse()
            try await LTICourseBinding.bind(
                course, platformID: try registered.requireID(), contextID: "context-1", on: app.db)

            let login = try await login()
            let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))
            var sessionCookie: String?
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .seeOther)
                #expect(res.headers.first(name: .location) == "/")
                sessionCookie = res.headers.setCookie?["vapor-session"].map { "vapor-session=\($0.string)" }
                #expect(res.headers.setCookie?[LTIRoutes.stateCookieName]?.maxAge == 0)
            }

            let identity = try #require(try await APILTIIdentity.query(on: app.db).first())
            #expect(identity.subject == "subject-1")
            let user = try #require(try await APIUser.find(identity.userID, on: app.db))
            #expect(user.username.hasPrefix("lti-"))
            #expect(user.authProvider == "lti")
            #expect(user.displayName == "Ada Lovelace")
            let enrollment = try #require(
                try await APICourseEnrollment.query(on: app.db).filter(\.$userID == identity.userID).first())
            #expect(enrollment.role == .student)
            #expect(enrollment.$course.id == course.id)

            let cookie = try #require(sessionCookie)
            try await get("/", cookie: cookie) { res in
                #expect(res.status == .ok)
            }
        }
    }

    @Test func aSecondLaunchReusesTheAccountAndKeepsTheEnrollment() async throws {
        try await withApp(app) { app in
            let registered = try await platform.install(on: app)
            let course = try await makeCourse()
            try await LTICourseBinding.bind(
                course, platformID: try registered.requireID(), contextID: "context-1", on: app.db)
            for _ in 0..<2 {
                let login = try await login()
                let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))
                try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                    #expect(res.status == .seeOther)
                }
            }
            let identities = try await APILTIIdentity.query(on: app.db).count()
            let enrollments = try await APICourseEnrollment.query(on: app.db).count()
            #expect(identities == 1)
            #expect(enrollments == 1)
        }
    }

    @Test func contextMatchingALEARNOrgUnitBindsItself() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let course = try await makeCourse(orgUnit: "context-1")
            let login = try await login()
            let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.headers.first(name: .location) == "/")
            }
            let bound = try #require(try await APICourse.find(course.id, on: app.db))
            #expect(bound.ltiContextID == "context-1")
        }
    }

    @Test func instructorFromAnUnboundContextLinksACourseTheyTeach() async throws {
        try await withApp(app) { app in
            let registered = try await platform.install(on: app)
            let course = try await makeCourse()
            let login = try await login()
            let token = try await platform.sign(
                LTITestPlatform.claims(nonce: login.nonce, roles: [LTITestPlatform.instructor]))
            var sessionCookie = ""
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.headers.first(name: .location) == "/lti/bind")
                sessionCookie = res.headers.setCookie?["vapor-session"].map { "vapor-session=\($0.string)" } ?? ""
            }
            // The launched instructor teaches the course in Chickadee.
            let userID = try #require(try await APILTIIdentity.query(on: app.db).first()).userID
            try await APICourseEnrollment(userID: userID, courseID: try course.requireID(), role: .instructor)
                .save(on: app.db)

            let (token2, boundCookie) = try await csrfFields(for: "/lti/bind", cookie: sessionCookie, on: app)
            try await app.asyncTest(
                .POST, "/lti/bind",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(
                        ["courseID": try course.requireID().uuidString, "_csrf": token2], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/")
                })
            let bound = try #require(try await APICourse.find(course.id, on: app.db))
            #expect(bound.ltiPlatformID == registered.id)
            #expect(bound.ltiContextID == "context-1")
            let actions = try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
            #expect(actions.contains(AuditAction.ltiCourseBound.rawValue))
        }
    }

    // MARK: - Refusals

    @Test func studentFromAnUnboundContextIsToldToAskTheInstructor() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let login = try await login()
            let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func loginFromAnUnregisteredIssuerIsRefused() async throws {
        try await withApp(app) { app in
            try await app.asyncTest(
                .GET, "/lti/login?iss=https://evil.example&login_hint=x&target_link_uri=http://localhost/lti/launch"
            ) { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func loginFromADisabledPlatformIsRefused() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app, enabled: false)
            let query =
                "iss=\(LTITestPlatform.issuer)&login_hint=x&target_link_uri=http://localhost/lti/launch"
                .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            try await app.asyncTest(.GET, "/lti/login?\(query)") { res in
                #expect(res.status == .forbidden)
            }
        }
    }

    @Test func launchWithoutTheStateCookieIsRefused() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let login = try await login()
            let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))
            try await launch(idToken: token, state: login.state, cookie: nil) { res in
                #expect(res.status == .unauthorized)
            }
            let identities = try await APILTIIdentity.query(on: app.db).count()
            #expect(identities == 0)
        }
    }

    @Test func replayedStateIsRefused() async throws {
        try await withApp(app) { app in
            let registered = try await platform.install(on: app)
            let course = try await makeCourse()
            try await LTICourseBinding.bind(
                course, platformID: try registered.requireID(), contextID: "context-1", on: app.db)
            let login = try await login()
            let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .seeOther)
            }
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func expiredStateIsRefused() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let login = try await login()
            let row = try #require(try await APILTILoginState.query(on: app.db).first())
            row.expiresAt = Date().addingTimeInterval(-1)
            try await row.save(on: app.db)
            let token = try await platform.sign(LTITestPlatform.claims(nonce: login.nonce))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func nonceFromAnotherLoginIsRefused() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let login = try await login()
            let token = try await platform.sign(LTITestPlatform.claims(nonce: "some-other-nonce"))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func tokenSignedByAnotherKeyIsRefused() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let impostor = try await LTITestPlatform.make()
            defer { impostor.cleanUp() }
            let login = try await login()
            let token = try await impostor.sign(LTITestPlatform.claims(nonce: login.nonce))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func claimRuleFailureIsRefused() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let login = try await login()
            let token = try await platform.sign(
                LTITestPlatform.claims(
                    nonce: login.nonce,
                    roles: ["http://purl.imsglobal.org/vocab/lis/v2/institution/person#Instructor"]))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .unauthorized)
            }
        }
    }

    @Test func deepLinkingRequestSentToTheLaunchEndpointIsRefused() async throws {
        try await withApp(app) { app in
            try await platform.install(on: app)
            let login = try await login()
            let token = try await platform.sign(
                LTITestPlatform.claims(
                    nonce: login.nonce, roles: [LTITestPlatform.instructor], messageType: "LtiDeepLinkingRequest"))
            try await launch(idToken: token, state: login.state, cookie: login.cookie) { res in
                #expect(res.status == .badRequest)
            }
        }
    }

    @Test func platformReportedErrorIsShownNotTrusted() async throws {
        try await withApp(app) { app in
            try await app.asyncTest(
                .POST, "/lti/launch",
                beforeRequest: { req in
                    try req.content.encode(["error": "login_required"], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .badRequest)
                })
        }
    }

    @Test func bindPageWithoutAPendingLaunchIsNotFound() async throws {
        try await withApp(app) { app in
            let cookie = try await loginUser(username: "lti_teacher", password: "testpassword", role: "user", on: app)
            try await get("/lti/bind", cookie: cookie) { res in
                #expect(res.status == .notFound)
            }
        }
    }
}
