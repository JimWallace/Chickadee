// Tests/APITests/LTI/LTIDeepLinkingTests.swift
//
// Deep Linking 2.0 end to end (docs/lti-1-3.md slice 3): a staff launch
// renders the picker, the chosen assignments come back as a response the
// tool key signed, the return form may post only to the platform's return
// URL, and a later launch of a returned link opens that assignment. The
// picker carries a single-use ticket instead of relying on the session,
// because the LMS shows it in a frame where the session cookie is not sent.

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

    /// What a launch returned.
    struct Launched {
        let status: HTTPStatus
        let location: String?
        let cookie: String
        let html: String
        let headers: HTTPHeaders
    }

    /// Runs login + launch and returns the launch response's status,
    /// location, session cookie, body and headers.
    private func launch(
        roles: [String] = [LTITestPlatform.instructor],
        messageType: String = "LtiDeepLinkingRequest",
        settings: LTIDeepLinkingSettings? = LTIDeepLinkingTests.settings(),
        custom: [String: JSONValue] = [:],
        cookie priorSession: String? = nil,
        stateCookieOverride: String? = nil,
        sendStateCookie: Bool = true
    ) async throws -> Launched {
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
        var result = Launched(status: .ok, location: nil, cookie: "", html: "", headers: [:])
        try await app.asyncTest(
            .POST, "/lti/launch",
            beforeRequest: { req in
                let sentState =
                    sendStateCookie
                    ? (stateCookieOverride.map { "\(LTIRoutes.stateCookieName)=\($0)" } ?? stateCookie) : nil
                let cookies = [sentState, priorSession].compactMap { $0 }.filter { !$0.isEmpty }
                if !cookies.isEmpty { req.headers.add(name: .cookie, value: cookies.joined(separator: "; ")) }
                try req.content.encode(["id_token": token, "state": state], as: .urlEncodedForm)
            },
            afterResponse: { res in
                let session = res.headers.setCookie?["vapor-session"].map { "vapor-session=\($0.string)" }
                result = Launched(
                    status: res.status, location: res.headers.first(name: .location),
                    cookie: session ?? priorSession ?? "", html: res.body.string, headers: res.headers)
            })
        return result
    }

    /// POSTs the picker with `publicIDs` chosen and `ticket`, with no cookie
    /// and no CSRF token: inside the LMS frame the browser sends neither.
    private func choose(
        _ publicIDs: [String], ticket: String, _ check: @escaping (TestingHTTPResponse) throws -> Void
    ) async throws {
        let body =
            (publicIDs.map { "assignments%5B%5D=\($0)" } + [
                "ticket=\(ticket.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
            ])
            .joined(separator: "&")
        try await app.asyncTest(
            .POST, "/lti/deep-link",
            beforeRequest: { req in
                req.headers.contentType = .urlEncodedForm
                req.body = .init(string: body)
            },
            afterResponse: check)
    }

    /// The `value` of the hidden ticket input on the picker.
    private static func ticket(in html: String) -> String? {
        guard let range = html.range(of: #"name="ticket" value=""#) else { return nil }
        let rest = html[range.upperBound...]
        return rest.firstIndex(of: "\"").map { String(rest[..<$0]) }
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
            #expect(launched.status == .ok)
            #expect(launched.location == nil)
            #expect(launched.html.contains("Lab 1"))
            #expect(launched.html.contains("Lab 2"))
            #expect(launched.html.contains("type=\"checkbox\""))
            let ticket = try #require(Self.ticket(in: launched.html))

            var html = ""
            var csp = ""
            try await choose([fixture.lab1.publicID, fixture.lab2.publicID], ticket: ticket) { res in
                #expect(res.status == .ok)
                html = res.body.string
                csp = res.headers.first(name: "Content-Security-Policy") ?? ""
            }
            #expect(html.contains("action=\"\(Self.returnURL)\""))
            #expect(csp.contains("form-action 'self' https://lms.example.edu"))

            let jwt = try #require(Self.jwt(in: html))
            let response = try await LTITestPlatform.verifyAsPlatform(
                jwt, signedBy: app.ltiToolKeyAuthority(), as: LTIDeepLinkingResponse.self)
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

            // The request is answered once: its ticket is dead afterwards.
            try await choose([fixture.lab1.publicID], ticket: ticket) { res in
                #expect(res.status == .notFound)
                #expect(!res.body.string.contains("name=\"JWT\""))
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

    /// The binding page needs the session, which the LMS frame does not
    /// carry, so a deep-linking launch from an unlinked course says how to
    /// link it instead, in a page the LMS frame may show.
    @Test func anUnlinkedContextIsRefusedWithHowToLinkIt() async throws {
        try await withApp(app) { app in
            _ = try await fixture(bind: false)
            let launched = try await launch()
            #expect(launched.status == .forbidden)
            #expect(launched.location == nil)
            #expect(launched.html.contains("Open a Chickadee link from this course in a new window once"))
            #expect(launched.headers.first(name: "X-Frame-Options") == nil)
            let count = try await APILTIDeepLinkRequest.query(on: app.db).count()
            #expect(count == 0)
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
            #expect(launched.html.contains("type=\"radio\""))
            let ticket = try #require(Self.ticket(in: launched.html))
            try await choose([fixture.lab1.publicID, fixture.lab2.publicID], ticket: ticket) { res in
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
            let ticket = try #require(Self.ticket(in: launched.html))
            try await choose([], ticket: ticket) { res in
                #expect(res.body.string.contains("Choose at least one assignment."))
                // A refused choice keeps the request open, under the same ticket.
                #expect(Self.ticket(in: res.body.string) == ticket)
            }
            try await choose([fixture.lab1.publicID, foreign.publicID], ticket: ticket) { res in
                #expect(res.body.string.contains("Choose at least one assignment."))
                #expect(!res.body.string.contains("name=\"JWT\""))
            }
        }
    }

    /// Each launch is its own request under its own ticket; nothing a later
    /// launch does in the session can answer or steer it, and a ticket no
    /// launch issued is refused.
    @Test func eachLaunchGetsItsOwnTicketAndAnUnknownOneIsRefused() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture()
            let first = try await launch()
            let second = try await launch(cookie: first.cookie)
            let firstTicket = try #require(Self.ticket(in: first.html))
            let secondTicket = try #require(Self.ticket(in: second.html))
            #expect(firstTicket != secondTicket)
            try await choose([fixture.lab1.publicID], ticket: firstTicket) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("name=\"JWT\""))
            }
            try await choose([fixture.lab1.publicID], ticket: "not-a-ticket") { res in
                #expect(res.status == .notFound)
            }
            try await choose([fixture.lab1.publicID], ticket: "") { res in
                #expect(res.status == .notFound)
            }
        }
    }

    // MARK: - The LMS frame

    /// The LMS frame can drop the state cookie even where the browser supports
    /// partitioned cookies. A deep-linking launch signs nobody in, so it does
    /// not need the cookie, and the picker still works.
    @Test func aDeepLinkingLaunchWorksWithoutTheStateCookieAndSignsNobodyIn() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            let launched = try await launch(sendStateCookie: false)
            #expect(launched.status == .ok)
            #expect(launched.headers.setCookie?["vapor-session"] == nil)
            let ticket = try #require(Self.ticket(in: launched.html))
            try await choose([fixture.lab1.publicID], ticket: ticket) { res in
                #expect(res.status == .ok)
                #expect(res.body.string.contains("name=\"JWT\""))
            }
            let actions = try await APIAuditLogEntry.query(on: app.db).all().map(\.action)
            #expect(!actions.contains(AuditAction.loginSuccess.rawValue))
        }
    }

    /// A cookie that names another login's state can only come from tampering
    /// or a crossed login, so it is refused even on a deep-linking launch.
    @Test func aDeepLinkingLaunchWithAnotherLoginsStateCookieIsRefused() async throws {
        try await withApp(app) { app in
            _ = try await fixture()
            let launched = try await launch(stateCookieOverride: "another-login")
            #expect(launched.status == .unauthorized)
            let count = try await APILTIDeepLinkRequest.query(on: app.db).count()
            #expect(count == 0)
        }
    }

    @Test func thePickerAndItsReturnPageMayBeFramedByThePlatformOnly() async throws {
        try await withApp(app) { _ in
            let fixture = try await fixture()
            let launched = try await launch()
            let csp = launched.headers.first(name: "Content-Security-Policy") ?? ""
            #expect(csp.contains("frame-ancestors 'self' \(LTITestPlatform.issuer)"))
            #expect(launched.headers.first(name: "X-Frame-Options") == nil)
            // Inside the frame the site nav would only lead to pages that
            // refuse to be framed, so the picker renders without it.
            #expect(!launched.html.contains("<nav class=\"nav\""))

            let ticket = try #require(Self.ticket(in: launched.html))
            try await choose([fixture.lab1.publicID], ticket: ticket) { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(csp.contains("frame-ancestors 'self' \(LTITestPlatform.issuer)"))
                #expect(res.headers.first(name: "X-Frame-Options") == nil)
                #expect(!res.body.string.contains("<nav class=\"nav\""))
            }
            // Every other page keeps the default.
            try await app.asyncTest(.GET, "/login") { res in
                let csp = res.headers.first(name: "Content-Security-Policy") ?? ""
                #expect(csp.contains("frame-ancestors 'self';"))
                #expect(res.headers.first(name: "X-Frame-Options") == "SAMEORIGIN")
            }
        }
    }

    @Test func anExpiredTicketIsRefused() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            let launched = try await launch()
            let ticket = try #require(Self.ticket(in: launched.html))
            let row = try #require(try await APILTIDeepLinkRequest.query(on: app.db).first())
            row.expiresAt = Date().addingTimeInterval(-1)
            try await row.save(on: app.db)
            try await choose([fixture.lab1.publicID], ticket: ticket) { res in
                #expect(res.status == .notFound)
                #expect(!res.body.string.contains("name=\"JWT\""))
            }
        }
    }

    @Test func aTicketStopsWorkingWhenItsUserIsNoLongerStaff() async throws {
        try await withApp(app) { app in
            let fixture = try await fixture()
            let launched = try await launch()
            let ticket = try #require(Self.ticket(in: launched.html))
            let enrollment = try #require(try await APICourseEnrollment.query(on: app.db).first())
            enrollment.role = .student
            try await enrollment.save(on: app.db)
            try await choose([fixture.lab1.publicID], ticket: ticket) { res in
                #expect(res.status == .forbidden)
                #expect(!res.body.string.contains("name=\"JWT\""))
            }
        }
    }

    @Test func theTicketIsStoredOnlyAsAHash() async throws {
        try await withApp(app) { app in
            _ = try await fixture()
            let launched = try await launch()
            let ticket = try #require(Self.ticket(in: launched.html))
            let row = try #require(try await APILTIDeepLinkRequest.query(on: app.db).first())
            #expect(row.ticketHash == LTILaunchSecrets.hash(ticket))
            #expect(row.ticketHash != ticket)
            #expect(row.returnURL == Self.returnURL)
            #expect(row.data == "opaque-data")
        }
    }
}
