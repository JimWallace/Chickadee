// Tests/APITests/Admin/AdminRoutesGateAndRefusalTests.swift
//
// The admin-only gate and the refusals of AdminRoutes that the larger
// AdminRoutesTests suite does not reach. A per-course instructor is not a
// deployment admin, so every admin page and form refuses them and changes
// nothing. An admin's role form refuses an unknown user and an unknown role.
// The alerts form refuses a webhook URL that is not http(s), saves and clears
// a good one, and the test-alert button reports a delivered and an undelivered
// alert. The user page and the delete form answer 404 for an unknown user. The
// unpaged users feed breaks a last-seen tie by username, and the Overview lists
// courses in natural code order.

import Core
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// A `Client` stub for the alert webhook. It answers every request with
/// `status` and counts the requests, so a test sees that a dispatch happened
/// without the network.
private struct AdminGateWebhookStubClient: Client {
    let eventLoop: any EventLoop
    let status: HTTPStatus
    let requests: NIOLockedValueBox<[String]>

    func delegating(to eventLoop: any EventLoop) -> any Client {
        AdminGateWebhookStubClient(eventLoop: eventLoop, status: status, requests: requests)
    }

    func send(_ request: ClientRequest) -> EventLoopFuture<ClientResponse> {
        requests.withLockedValue { $0.append(request.url.string) }
        return eventLoop.makeSucceededFuture(ClientResponse(status: status))
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) final class AdminRoutesGateAndRefusalTests {

    let app: Application
    let webhookFile: String

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-admin-gate")
        // The monitor persists the webhook URL to this file. Without it, the
        // file goes to the working directory.
        webhookFile =
            FileManager.default.temporaryDirectory
            .appendingPathComponent("admin-gate-webhook-\(UUID().uuidString)").path
        app.alertWebhookURLFilePath = webhookFile
    }

    deinit {
        try? FileManager.default.removeItem(atPath: webhookFile)
    }

    /// POSTs a form with a CSRF token bound to `cookie`, and returns the
    /// status and the redirect target.
    private func post(
        _ path: String, fields: [String: String] = [:], cookie: String
    ) async throws -> (status: HTTPStatus, location: String?) {
        let (token, bound) = try await csrfFields(for: "/account", cookie: cookie, on: app)
        var status: HTTPStatus = .ok
        var location: String?
        try await app.asyncTest(
            .POST, path,
            beforeRequest: { req in
                req.headers.add(name: .cookie, value: bound)
                try req.content.encode(fields.merging(["_csrf": token]) { $1 }, as: .urlEncodedForm)
            },
            afterResponse: { res in
                status = res.status
                location = res.headers.first(name: .location)
            })
        return (status, location)
    }

    /// Signs in a deployment `user` who is the instructor of a course, and
    /// returns the session cookie.
    private func loginCourseInstructor(_ username: String) async throws -> String {
        let course = try await makeTestCourse(on: app, code: "GATE\(username.count)")
        let cookie = try await loginUser(username: username, password: "pw", role: "user", on: app)
        let prof = try #require(try await APIUser.query(on: app.db).filter(\.$username == username).first())
        try await APICourseEnrollment(userID: prof.requireID(), courseID: course.requireID(), role: .instructor)
            .save(on: app.db)
        return cookie
    }

    private func role(of username: String) async throws -> String? {
        try await APIUser.query(on: app.db).filter(\.$username == username).first()?.role
    }

    // MARK: - The admin-only gate

    @Test(arguments: [
        "/admin",
        "/admin/users",
        "/admin/users-data",
        "/admin/alerts",
        "/admin/runners",
        "/admin/storage",
        "/admin/audit",
    ])
    func aCourseInstructorIsRefusedEveryAdminPage(path: String) async throws {
        try await withApp(app) { _ in
            let cookie = try await loginCourseInstructor("gate_prof")

            let response = try await getResponse(path, cookie: cookie, on: app)

            #expect(response.status == .forbidden)
        }
    }

    @Test func aCourseInstructorCannotSeeAnotherUsersAdminPage() async throws {
        try await withApp(app) { _ in
            let student = try await makeTestUser(on: app, username: "gate_target")
            let cookie = try await loginCourseInstructor("gate_prof_detail")

            let response = try await getResponse(
                "/admin/users/\(student.requireID().uuidString)", cookie: cookie, on: app)

            #expect(response.status == .forbidden)
            #expect(!response.body.string.contains("gate_target"))
        }
    }

    @Test func aCourseInstructorCannotMakeAnyoneAnAdmin() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginCourseInstructor("gate_prof_role")
            let prof = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "gate_prof_role").first())
            let student = try await makeTestUser(on: app, username: "gate_role_target")

            let forOther = try await post(
                "/admin/users/\(student.requireID().uuidString)/role", fields: ["role": "admin"], cookie: cookie)
            let forSelf = try await post(
                "/admin/users/\(prof.requireID().uuidString)/role", fields: ["role": "admin"], cookie: cookie)

            #expect(forOther.status == .forbidden)
            #expect(forSelf.status == .forbidden)
            #expect(try await role(of: "gate_role_target") == "student")
            #expect(try await role(of: "gate_prof_role") == "user")
        }
    }

    @Test func aCourseInstructorCannotDeleteAUser() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginCourseInstructor("gate_prof_delete")
            let student = try await makeTestUser(on: app, username: "gate_delete_target")
            let studentID = try student.requireID()

            let response = try await post("/admin/users/\(studentID.uuidString)/delete", cookie: cookie)

            #expect(response.status == .forbidden)
            #expect(try await APIUser.find(studentID, on: app.db) != nil)
        }
    }

    @Test func aCourseInstructorCannotChangeTheAlertWebhook() async throws {
        try await withApp(app) { _ in
            await app.serverHealthAlertMonitor.setWebhookURL("https://hooks.example.test/kept")
            let cookie = try await loginCourseInstructor("gate_prof_alerts")

            let response = try await post(
                "/admin/alerts/config", fields: ["webhookURL": "https://evil.example.test/hook"], cookie: cookie)

            #expect(response.status == .forbidden)
            #expect(await app.serverHealthAlertMonitor.effectiveWebhookURL() == "https://hooks.example.test/kept")
        }
    }

    // MARK: - POST /admin/users/:userID/role

    @Test(arguments: ["not-a-uuid", "00000000-0000-0000-0000-000000000000"])
    func aRoleChangeForAnUnknownUserIsNotFound(userID: String) async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("gate_admin_role404", on: app)

            let response = try await post("/admin/users/\(userID)/role", fields: ["role": "admin"], cookie: cookie)

            #expect(response.status == .notFound)
        }
    }

    /// The deployment role is user or admin. The retired roles and the
    /// agent-only `mcp` role are refused, and the stored role stays.
    @Test(arguments: ["instructor", "student", "mcp", "superuser", ""])
    func aRoleOutsideUserAndAdminIsRefused(newRole: String) async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("gate_admin_badrole", on: app)
            let target = try await makeTestUser(on: app, username: "gate_badrole_target", role: "user")

            let response = try await post(
                "/admin/users/\(target.requireID().uuidString)/role", fields: ["role": newRole], cookie: cookie)

            #expect(response.status == .badRequest)
            #expect(try await role(of: "gate_badrole_target") == "user")
        }
    }

    // MARK: - GET /admin/users/:userID and POST …/delete

    @Test(arguments: ["not-a-uuid", "00000000-0000-0000-0000-000000000000"])
    func theUserPageOfAnUnknownUserIsNotFound(userID: String) async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("gate_admin_detail404", on: app)

            let response = try await getResponse("/admin/users/\(userID)", cookie: cookie, on: app)

            #expect(response.status == .notFound)
        }
    }

    @Test func deletingAnUnknownUserIsNotFoundAndDeletesNobody() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("gate_admin_delete404", on: app)
            let before = try await APIUser.query(on: app.db).count()

            let response = try await post(
                "/admin/users/\(UUID().uuidString)/delete", cookie: cookie)

            #expect(response.status == .notFound)
            #expect(try await APIUser.query(on: app.db).count() == before)
        }
    }

    // MARK: - POST /admin/alerts/config

    @Test(arguments: ["ftp://hooks.example.test/x", "hooks.example.test/no-scheme", "javascript:alert(1)"])
    func aWebhookURLThatIsNotHTTPIsRefusedAndTheOldOneStays(candidate: String) async throws {
        try await withApp(app) { _ in
            await app.serverHealthAlertMonitor.setWebhookURL("https://hooks.example.test/kept")
            let cookie = try await loginAsAdmin("gate_admin_badhook", on: app)

            let response = try await post("/admin/alerts/config", fields: ["webhookURL": candidate], cookie: cookie)

            let location = try #require(response.location)
            #expect(location.hasPrefix("/admin/alerts?error="))
            #expect(location.contains("http"))
            #expect(await app.serverHealthAlertMonitor.effectiveWebhookURL() == "https://hooks.example.test/kept")
        }
    }

    @Test func aGoodWebhookURLIsSavedTrimmedAndPersisted() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("gate_admin_goodhook", on: app)

            let response = try await post(
                "/admin/alerts/config", fields: ["webhookURL": "  HTTPS://hooks.example.test/new  "], cookie: cookie)

            #expect(response.location == adminNoticeRedirect("/admin/alerts", ok: "Webhook saved."))
            #expect(await app.serverHealthAlertMonitor.effectiveWebhookURL() == "HTTPS://hooks.example.test/new")
            let onDisk = try String(contentsOfFile: webhookFile, encoding: .utf8)
            #expect(onDisk == "HTTPS://hooks.example.test/new")
        }
    }

    @Test func aBlankWebhookURLClearsTheSavedOne() async throws {
        try await withApp(app) { _ in
            await app.serverHealthAlertMonitor.setWebhookURL("https://hooks.example.test/old")
            let cookie = try await loginAsAdmin("gate_admin_clearhook", on: app)

            let response = try await post("/admin/alerts/config", fields: ["webhookURL": "   "], cookie: cookie)

            #expect(response.location == adminNoticeRedirect("/admin/alerts", ok: "Webhook cleared."))
            #expect(!FileManager.default.fileExists(atPath: webhookFile))
            // The test app sets no webhook in the environment, so nothing is left.
            #expect(await app.serverHealthAlertMonitor.effectiveWebhookURL() == nil)
        }
    }

    // MARK: - POST /admin/alerts/test

    @Test func aTestAlertThatTheWebhookAcceptsReportsSuccess() async throws {
        try await withApp(app) { _ in
            let requests = NIOLockedValueBox<[String]>([])
            app.clients.use { app in
                AdminGateWebhookStubClient(
                    eventLoop: app.eventLoopGroup.next(), status: .noContent, requests: requests)
            }
            await app.serverHealthAlertMonitor.setWebhookURL("https://hooks.example.test/ok")
            let cookie = try await loginAsAdmin("gate_admin_testalert", on: app)

            let response = try await post("/admin/alerts/test", cookie: cookie)

            #expect(response.location == adminNoticeRedirect("/admin/alerts", ok: "Test alert dispatched to webhook."))
            #expect(requests.withLockedValue { $0 } == ["https://hooks.example.test/ok"])
            let firing = try #require(await app.serverHealthAlertMonitor.recentFiringsSnapshot().last)
            #expect(firing.delivered)
        }
    }

    @Test func aTestAlertThatTheWebhookRejectsReportsAnErrorAndRecordsIt() async throws {
        try await withApp(app) { _ in
            let requests = NIOLockedValueBox<[String]>([])
            app.clients.use { app in
                AdminGateWebhookStubClient(
                    eventLoop: app.eventLoopGroup.next(), status: .internalServerError, requests: requests)
            }
            await app.serverHealthAlertMonitor.setWebhookURL("https://hooks.example.test/down")
            let cookie = try await loginAsAdmin("gate_admin_testalert_fail", on: app)

            let response = try await post("/admin/alerts/test", cookie: cookie)

            let location = try #require(response.location)
            #expect(location.hasPrefix("/admin/alerts?error="))
            #expect(location.contains("not%20delivered"))
            #expect(requests.withLockedValue { $0.count } == 1)
            let firing = try #require(await app.serverHealthAlertMonitor.recentFiringsSnapshot().last)
            #expect(!firing.delivered)
            #expect(firing.deliveryError?.contains("500") == true)
        }
    }

    // MARK: - Ordering

    /// The unpaged JSON feed puts the most recently seen first and breaks a
    /// tie on the same instant by username. A user never seen comes last.
    @Test func theUnpagedUsersFeedBreaksALastSeenTieByUsername() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("gate_admin_feed", on: app)
            let instant = Date(timeIntervalSince1970: 1_800_000_000)
            for name in ["tie_zulu", "tie_alpha"] {
                let user = try await makeTestUser(on: app, username: name)
                user.lastSeenAt = instant
                try await user.save(on: app.db)
            }
            _ = try await makeTestUser(on: app, username: "tie_never")

            let response = try await getResponse("/admin/users-data", cookie: cookie, on: app)

            #expect(response.status == .ok)
            let names = try response.content.decode([AdminUserRow].self).map(\.username)
            let alpha = try #require(names.firstIndex(of: "tie_alpha"))
            let zulu = try #require(names.firstIndex(of: "tie_zulu"))
            let never = try #require(names.firstIndex(of: "tie_never"))
            #expect(alpha < zulu)
            #expect(zulu < never)
        }
    }

    /// The Overview lists active courses by code in natural order, so CS9
    /// comes before CS10 whatever order they were made in.
    @Test func theOverviewListsCoursesInNaturalCodeOrder() async throws {
        try await withApp(app) { _ in
            _ = try await makeTestCourse(on: app, code: "ORD10", name: "Course Ten")
            _ = try await makeTestCourse(on: app, code: "ORD9", name: "Course Nine")
            _ = try await makeTestCourse(on: app, code: "ORD100", name: "Course Hundred")
            let cookie = try await loginAsAdmin("gate_admin_overview", on: app)

            let html = try await getHTML("/admin", cookie: cookie, on: app)

            let nine = try #require(html.range(of: "Course Nine")?.lowerBound)
            let ten = try #require(html.range(of: "Course Ten")?.lowerBound)
            let hundred = try #require(html.range(of: "Course Hundred")?.lowerBound)
            #expect(nine < ten)
            #expect(ten < hundred)
        }
    }
}
