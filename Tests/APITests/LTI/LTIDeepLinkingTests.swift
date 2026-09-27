// Tests/APITests/LTI/LTIDeepLinkingTests.swift
//
// Deep Linking 2.0 end to end (docs/lti-1-3.md slice 3): a staff launch
// reaches the picker, the chosen assignments come back as a response the
// tool key signed, the return form may post only to the platform's return
// URL, and a later launch of a returned link opens that assignment.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized) final class LTIDeepLinkingTests {
    let app: Application
    let platform: LTITestPlatform
    let keyDirectory: URL

    static let returnURL = "https://lms.example.edu/deep-link/return"

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-lti-deep-link")
        platform = try await LTITestPlatform.make()
        keyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-lti-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: keyDirectory, withIntermediateDirectories: true)
        app.ltiToolKeyFilePath = keyDirectory.appendingPathComponent(".lti-tool-key").path
        // The test app does not install the production middleware stack; the
        // return page's form-action allowance is asserted on a real header.
        app.middleware.use(SecurityHeadersMiddleware())
    }

    deinit {
        platform.cleanUp()
        try? FileManager.default.removeItem(at: keyDirectory)
    }

    struct Fixture {
        let platform: APILTIPlatform
        let course: APICourse
        let lab1: APIAssignment
        let lab2: APIAssignment
    }

    /// A registered platform, a course bound to `context-1`, two assignments.
    private func fixture(bind: Bool = true) async throws -> Fixture {
        let registered = try await platform.install(on: app)
        let course = try await makeTestCourse(on: app, code: "CS135", name: "Designing Functional Programs")
        let courseID = try course.requireID()
        if bind {
            try await LTICourseBinding.bind(
                course, platformID: try registered.requireID(), contextID: "context-1", on: app.db)
        }
        try await makeTestSetup(on: app, id: "setup-1", courseID: courseID)
        try await makeTestSetup(on: app, id: "setup-2", courseID: courseID)
        let lab1 = try await makeTestAssignment(on: app, testSetupID: "setup-1", courseID: courseID, title: "Lab 1")
        let lab2 = try await makeTestAssignment(on: app, testSetupID: "setup-2", courseID: courseID, title: "Lab 2")
        return Fixture(platform: registered, course: course, lab1: lab1, lab2: lab2)
    }

    static func settings(
        returnURL: String = returnURL, acceptTypes: [String] = ["ltiResourceLink"], acceptMultiple: Bool = true
    ) -> LTIDeepLinkingSettings {
        LTIDeepLinkingSettings(
            deepLinkReturnURL: returnURL, acceptTypes: acceptTypes, acceptMultiple: acceptMultiple,
            data: "opaque-data")
    }

    /// Runs login + launch and returns the launch response's location and
    /// session cookie.
    private func launch(
        roles: [String] = [LTITestPlatform.instructor],
        messageType: String = "LtiDeepLinkingRequest",
        settings: LTIDeepLinkingSettings? = LTIDeepLinkingTests.settings(),
        custom: [String: JSONValue] = [:],
        cookie priorSession: String? = nil
    ) async throws -> (status: HTTPStatus, location: String?, cookie: String) {
        var state = ""
        var nonce = ""
        var stateCookie = ""
        let query =
            "iss=\(LTITestPlatform.issuer)&login_hint=h&target_link_uri=http://localhost/lti/launch"
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
        try await app.asyncTest(.GET, "/lti/login?\(query)") { res in
            let location = try #require(res.headers.first(name: .location))
            let items = URLComponents(string: location)?.queryItems ?? []
            state = items.first { $0.name == "state" }?.value ?? ""
            nonce = items.first { $0.name == "nonce" }?.value ?? ""
            stateCookie =
                "\(LTIRoutes.stateCookieName)=\(res.headers.setCookie?[LTIRoutes.stateCookieName]?.string ?? "")"
        }
        var claims = LTITestPlatform.claims(nonce: nonce, roles: roles, messageType: messageType, custom: custom)
        claims.deepLinkingSettings = settings
        let token = try await platform.sign(claims)
        var result: (HTTPStatus, String?, String) = (.ok, nil, "")
        try await app.asyncTest(
            .POST, "/lti/launch",
            beforeRequest: { req in
                req.headers.add(
                    name: .cookie, value: [stateCookie, priorSession].compactMap { $0 }.joined(separator: "; "))
                try req.content.encode(["id_token": token, "state": state], as: .urlEncodedForm)
            },
            afterResponse: { res in
                let session = res.headers.setCookie?["vapor-session"].map { "vapor-session=\($0.string)" }
                result = (res.status, res.headers.first(name: .location), session ?? priorSession ?? "")
            })
        return (status: result.0, location: result.1, cookie: result.2)
    }

    /// POSTs the picker with `publicIDs` chosen, CSRF included.
    private func choose(
        _ publicIDs: [String], cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        let (token, boundCookie) = try await csrfFields(for: "/lti/deep-link", cookie: cookie, on: app)
        let body =
            (publicIDs.map { "assignments%5B%5D=\($0)" } + [
                "_csrf=\(token.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            ])
            .joined(separator: "&")
        try await app.asyncTest(
            .POST, "/lti/deep-link",
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: boundCookie)
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: body)
            },
            afterResponse: check)
    }

    private func get(
        _ path: String, cookie: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: check)
    }

    /// The `value` of the hidden JWT input on the return page.
    private static func jwt(in html: String) -> String? {
        guard let range = html.range(of: #"name="JWT" value=""#) else { return nil }
        let rest = html[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
    }

    // MARK: - Happy path

    @Test func staffChooseAssignmentsAndGetASignedResponseForTheReturnURL() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            let launched = try await launch()
            #expect(launched.location == "/lti/deep-link")

            try await get("/lti/deep-link", cookie: launched.cookie) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("Lab 1"))
                #expect(res.body.string.contains("Lab 2"))
                #expect(res.body.string.contains("type=\"checkbox\""))
            }

            var html = ""
            var csp = ""
            try await choose([fixture.lab1.publicID, fixture.lab2.publicID], cookie: launched.cookie) { res in
                #expect(res.status == .ok)
                html = res.body.string
                csp = res.headers.first(name: "Content-Security-Policy") ?? ""
            }
            #expect(html.contains("action=\"\(Self.returnURL)\""))
            #expect(csp.contains("form-action 'self' https://lms.example.edu"))

            let jwt = try #require(Self.jwt(in: html))
            let response = try await app.ltiToolKeyAuthority().verify(jwt, as: LTIDeepLinkingResponse.self)
            #expect(response.iss.value == LTITestPlatform.clientID)
            #expect(response.aud.value == [LTITestPlatform.issuer])
            #expect(response.messageType == "LtiDeepLinkingResponse")
            #expect(response.deploymentID == LTITestPlatform.deploymentID)
            #expect(response.data == "opaque-data")
            #expect(response.contentItems.map(\.title) == ["Lab 1", "Lab 2"])
            #expect(
                response.contentItems.allSatisfy { $0.type == "ltiResourceLink" && $0.url.hasSuffix("/lti/launch") })
            #expect(response.contentItems.first?.custom["assignment"] == fixture.lab1.publicID)

            let actions = try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
            #expect(actions.contains(AuditAction.ltiContentLinked.rawValue))

            // The request is answered once: the picker is gone afterwards.
            try await get("/lti/deep-link", cookie: launched.cookie) { res in
                #expect(res.status == .notFound)
            }
        }
    }

    @Test func aReturnedLinkLaunchesItsAssignment() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture()
            let launched = try await launch(
                roles: [LTITestPlatform.learner], messageType: "LtiResourceLinkRequest", settings: nil,
                custom: ["assignment": .string(fixture.lab2.publicID)])
            #expect(
                launched.location == VanityURLRoutes.vanityPath(courseCode: "CS135", assignmentSlug: fixture.lab2.slug))
        }
    }

    @Test func anAssignmentFromAnotherCourseFallsBackToTheDashboard() async throws {
        try await withApp(app) { app in
            _ = try await fixture()
            let other = try await makeTestCourse(on: app, code: "OTHER1")
            try await makeTestSetup(on: app, id: "setup-x", courseID: try other.requireID())
            let foreign = try await makeTestAssignment(on: app, testSetupID: "setup-x", courseID: try other.requireID())
            let launched = try await launch(
                roles: [LTITestPlatform.learner], messageType: "LtiResourceLinkRequest", settings: nil,
                custom: ["assignment": .string(foreign.publicID)])
            #expect(launched.location == "/")
        }
    }

    @Test func anUnlinkedContextBindsFirstThenReturnsToThePicker() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture(bind: false)
            let launched = try await launch()
            #expect(launched.location == "/lti/bind")
            let userID = try #require(try await APILTIIdentity.query(on: app.db).first()).userID
            try await APICourseEnrollment(userID: userID, courseID: try fixture.course.requireID(), role: .instructor)
                .save(on: app.db)
            let (token, boundCookie) = try await csrfFields(for: "/lti/bind", cookie: launched.cookie, on: app)
            try await app.asyncTest(
                .POST, "/lti/bind",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(
                        ["courseID": try fixture.course.requireID().uuidString, "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.headers.first(name: .location) == "/lti/deep-link")
                })
        }
    }

    // MARK: - Refusals

    @Test func aStudentCannotDeepLink() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let launched = try await launch(roles: [LTITestPlatform.learner])
            #expect(launched.status == .forbidden)
        }
    }

    @Test func aPlatformThatDoesNotAcceptResourceLinksIsRefused() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let launched = try await launch(settings: Self.settings(acceptTypes: ["file", "html"]))
            #expect(launched.status == .badRequest)
        }
    }

    @Test func anInsecureReturnURLIsRefused() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let launched = try await launch(settings: Self.settings(returnURL: "http://evil.example/return"))
            #expect(launched.status == .badRequest)
        }
    }

    @Test func singleChoicePlatformsGetRadiosAndRefuseTwo() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture()
            let launched = try await launch(settings: Self.settings(acceptMultiple: false))
            try await get("/lti/deep-link", cookie: launched.cookie) { res in
                #expect(res.body.string.contains("type=\"radio\""))
            }
            try await choose([fixture.lab1.publicID, fixture.lab2.publicID], cookie: launched.cookie) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("one assignment at a time"))
                #expect(!res.body.string.contains("name=\"JWT\""))
            }
        }
    }

    @Test func choosingNothingOrAForeignAssignmentIsRefused() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            let other = try await makeTestCourse(on: app, code: "OTHER1")
            try await makeTestSetup(on: app, id: "setup-x", courseID: try other.requireID())
            let foreign = try await makeTestAssignment(on: app, testSetupID: "setup-x", courseID: try other.requireID())
            let launched = try await launch()
            try await choose([], cookie: launched.cookie) { res in
                #expect(res.body.string.contains("Choose at least one assignment."))
            }
            try await choose([fixture.lab1.publicID, foreign.publicID], cookie: launched.cookie) { res in
                #expect(res.body.string.contains("Choose at least one assignment."))
                #expect(!res.body.string.contains("name=\"JWT\""))
            }
        }
    }

    @Test func aLaterResourceLaunchClearsAnUnansweredRequest() async throws {
        try await withApp(app) { _ in
            _ = try await fixture()
            let first = try await launch()
            #expect(first.location == "/lti/deep-link")
            let second = try await launch(
                messageType: "LtiResourceLinkRequest", settings: nil, cookie: first.cookie)
            #expect(second.location == "/")
            try await get("/lti/deep-link", cookie: second.cookie) { res in
                #expect(res.status == .notFound)
            }
        }
    }
}
