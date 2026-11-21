// Tests/APITests/Admin/AdminRoutesTests.swift
//
// AdminRoutes, through the `AdminRouteFixtures` helpers.
//
// `AdminRoutesGateAndRefusalTests` covers the admin-only gate and the
// refusals. A per-course instructor is not a deployment admin, so every admin
// page and form refuses them and changes nothing. An admin's role form refuses
// an unknown user and an unknown role. The alerts form refuses a webhook URL
// that is not http(s), saves and clears a good one, and the test-alert button
// reports a delivered and an undelivered alert. The user page and the delete
// form answer 404 for an unknown user. The unpaged users feed breaks a
// last-seen tie by username, and the Overview lists courses in natural code
// order.

import Core
import Fluent
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOFoundationCompat
import Testing
import Vapor
import VaporTesting

@testable import APIServer

/// Trivial tail of a middleware chain for unit-testing a single middleware.
private struct PassthroughResponder: AsyncResponder {
    func respond(to request: Request) async throws -> Response {
        Response(status: .ok)
    }
}

@Suite(.serialized) final class AdminRoutesTests: AdminRouteFixtures {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin")
    }

    @Test func changeRoleUpdatesUserRole() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let target = try await makeUser(username: "role_target", role: "user")
            let userID = try target.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(cookie)

            // The deployment role is user|admin now (#417 Slice G2).
            try await app.asyncTest(
                .POST, "/admin/users/\(userID.uuidString)/role",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["role": "admin", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin/users")
                })

            let updated = try await APIUser.find(userID, on: app.db)
            #expect(updated?.role == "admin")

        }
    }

    @Test func changeRoleRefusesTheAdminsOwnAccount() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let me = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "admin_routes").first())
            let myID = try me.requireID()
            let (boundCookie, token) = try await csrfCookieAndToken(cookie)

            try await app.asyncTest(
                .POST, "/admin/users/\(myID.uuidString)/role",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["role": "user", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .forbidden)
                })

            let unchanged = try await APIUser.find(myID, on: app.db)
            #expect(unchanged?.role == "admin")
        }
    }

    @Test func usersListShowsNoRoleMenuOnTheViewersOwnRow() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let me = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "admin_routes").first())
            let other = try await makeUser(username: "role_other", role: "user")
            let myMenu = "id=\"role-\(try me.requireID().uuidString)\""
            let otherMenu = "id=\"role-\(try other.requireID().uuidString)\""

            /// The opening `<select …>` tag that carries `marker`.
            func selectTag(in body: String, marker: String) -> String? {
                guard let start = body.range(of: marker),
                    let end = body[start.upperBound...].firstIndex(of: ">")
                else { return nil }
                return String(body[start.lowerBound..<end])
            }

            try await app.asyncTest(
                .GET, "/admin/users-data?fragment=rows",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    let body = String(buffer: res.body)
                    let mine = selectTag(in: body, marker: myMenu)
                    let theirs = selectTag(in: body, marker: otherMenu)
                    // Your own row has no role menu at all, only a badge (#3007).
                    #expect(mine == nil)
                    #expect(theirs != nil)
                    #expect(theirs?.contains("disabled") == false)
                })
        }
    }

    @Test func adminPageOffersNoRunnerSecretControls() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let (boundCookie, token) = try await csrfCookieAndToken(cookie)

            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!res.body.string.contains("runner-secret"))
                    #expect(!res.body.string.contains("Worker shared secret"))
                })

            try await app.asyncTest(
                .POST, "/admin/runner-secret",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    try req.content.encode(["secret": "new-secret", "_csrf": token], as: .urlEncodedForm)
                },
                afterResponse: { res in
                    #expect(res.status == .notFound)
                })
        }
    }

    @Test func writeWorkerSecretToDiskSetsOwnerOnlyPermissions() async throws {
        try await withApp(app) { _ in
            // The worker secret is the HMAC signing key for runner↔server
            // requests; default umask leaves it world-readable on Linux, so
            // writeWorkerSecretToDisk must enforce 0o600.
            let path = app.workerSecretFilePath
            writeWorkerSecretToDisk(secret: "mode-check-secret", workerSecretFilePath: path)

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(perms & 0o777 == 0o600, "Expected .worker-secret to be 0600; got \(String(perms, radix: 8))")

        }
    }

    @Test func readWorkerSecretFromDiskTightensExistingPermissions() async throws {
        try await withApp(app) { _ in
            // Files written by older builds may be world-readable; read-time
            // hardening ensures upgraded installs converge on 0o600.
            let path = app.workerSecretFilePath
            try "legacy-secret".write(
                toFile: path, atomically: true, encoding: .utf8
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o644)], ofItemAtPath: path
            )

            _ = readWorkerSecretFromDisk(workerSecretFilePath: path)

            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? 0
            #expect(perms & 0o777 == 0o600)

        }
    }

    @Test func updateLocalRunnerAutoStartPersistsSetting() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let (boundCookie, token) = try await csrfCookieAndToken(cookie)

            try await app.asyncTest(
                .POST, "/admin/runner-autostart",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: boundCookie)
                    req.body = .init(string: "localRunnerAutoStart=on&_csrf=\(token)")
                    req.headers.replaceOrAdd(name: .contentType, value: "application/x-www-form-urlencoded")
                },
                afterResponse: { res in
                    #expect(res.status == .seeOther)
                    #expect(res.headers.first(name: .location) == "/admin")
                })

            let isEnabled = await app.localRunnerAutoStartStore.isEnabled()
            #expect(isEnabled)
            #expect(readLocalRunnerAutoStartFromDisk(filePath: app.localRunnerAutoStartFilePath) == true)

        }
    }

    @Test func adminDashboardShowsJobsProcessedCardLabel() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)

            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    // The window prefix lives in a chip span the sparkline
                    // cycler rewrites (24h → 7d → 30d).
                    #expect(body.contains("</span> Jobs Processed"))
                    #expect(body.contains("Peak Util") == false)
                })

        }
    }

    @Test func storageTabShowsBreakdown() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)

            try await app.asyncTest(
                .GET, "/admin/storage",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains(">Storage<"))
                    #expect(body.contains(">Submissions<"))
                    #expect(body.contains(">Test Setups<"))
                    #expect(body.contains(">Database<"))
                    #expect(body.contains("aria-current=\"page\""))
                })

            // The Storage panel must no longer appear on the Overview tab.
            // (Use a storage-only label — the Overview courses table now has its
            // own "Submissions" column header.)
            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains(">Test Setups<") == false)
                })
        }
    }

    @Test func adminTabBarPresentWithOverviewActive() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            try await app.asyncTest(
                .GET, "/admin",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("class=\"admin-tabs\""))
                    #expect(body.contains("href=\"/admin/users\""))
                    #expect(body.contains("href=\"/admin/storage\""))
                    #expect(body.contains("href=\"/admin/audit\""))
                    #expect(body.contains("href=\"/admin/alerts\""))
                    // Overview is the active tab.
                    #expect(body.contains("href=\"/admin\" aria-current=\"page\""))
                    // The inline audit/alerts buttons were removed from Overview.
                    #expect(body.contains(">Server health alerts</a>") == false)
                })
        }
    }

    @Test func usersTabDefaultsToMostRecentLastSeenFirst() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let now = Date()
            _ = try await makeUser(username: "never_seen")
            let older = try await makeUser(username: "older_seen", role: "student")
            older.lastSeenAt = now.addingTimeInterval(-3600)
            try await older.save(on: app.db)
            let recent = try await makeUser(username: "recent_seen", role: "student")
            recent.lastSeenAt = now
            try await recent.save(on: app.db)

            try await app.asyncTest(
                .GET, "/admin/users",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("data-sort-key=\"last-seen\""))
                    // The load-time sort is declared in markup and applied by
                    // the shared sortable-table.js, so this asserts the
                    // declaration rather than a page script's call.
                    #expect(body.contains("data-sort-initial=\"last-seen:desc\""))
                    let recentIndex = try #require(body.range(of: "recent_seen")?.lowerBound)
                    let olderIndex = try #require(body.range(of: "older_seen")?.lowerBound)
                    let neverIndex = try #require(body.range(of: "never_seen")?.lowerBound)
                    #expect(recentIndex < olderIndex)
                    #expect(olderIndex < neverIndex)
                })

        }
    }

    // MARK: - Users tab auto-refresh (#users-data feed)

    @Test func usersDataReturnsJSONRows() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            _ = try await makeUser(username: "json_feed_user", role: "instructor")

            try await app.asyncTest(
                .GET, "/admin/users-data",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.headers.contentType == .json)
                    let rows = try res.content.decode([AdminUserRow].self)
                    #expect(rows.contains { $0.username == "json_feed_user" && $0.role == "instructor" })
                    #expect(rows.contains { $0.username == "admin_routes" })
                })
        }
    }

    /// `?fragment=rows` renders the SAME partial the page renders, so the
    /// 5-second poll and the page cannot drift.  Before this the poll rebuilt
    /// every row as a JS string — a second copy of the markup that could (and
    /// did) diverge from the template silently.
    @Test func usersDataFragmentRendersTheSameRowsPartial() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            _ = try await makeUser(username: "fragment_user", role: "instructor")

            try await app.asyncTest(
                .GET, "/admin/users-data?fragment=rows",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    // Rows only — no <table>, no <thead>: the client swaps this
                    // into the existing tbody.
                    #expect(body.contains("<tr>"))
                    #expect(!body.contains("<table"))
                    #expect(!body.contains("<thead"))
                    #expect(body.contains("fragment_user"))
                    // The full row markup the page renders, not a reduced copy:
                    // the role form, its CSRF field, and the sortable timestamp.
                    #expect(body.contains("name=\"_csrf\""))
                    #expect(body.contains("js-relative-time"))
                })
        }
    }

    /// The runners feed keeps its JSON representation (the runner-detail page's
    /// poll reads it) and gains a rows fragment for the dashboard table.
    @Test func runnersFeedServesBothJSONAndFragment() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)

            try await app.asyncTest(
                .GET, "/admin/runners",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.headers.contentType == .json)
                })
            try await app.asyncTest(
                .GET, "/admin/runners?fragment=rows",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(!String(buffer: res.body).contains("<table"))
                })
        }
    }

    /// A system-generated poll (carrying `X-Background-Refresh`) must not count
    /// as activity, so a dashboard left open in a tab can't keep a user logged
    /// in past the idle timeout.  A normal request still refreshes activity.
    /// Driven through `UserActivityMiddleware.respond` directly because the
    /// minimal test app doesn't wire the global activity-tracking middleware.
    @Test func backgroundRefreshHeaderSkipsActivityRefresh() async throws {
        try await withApp(app) { _ in
            let user = try await makeUser(username: "activity_probe", role: "student")
            let userID = try user.requireID()
            let stale = Date().addingTimeInterval(-3600)
            user.lastSeenAt = stale
            try await user.save(on: app.db)

            let middleware = UserActivityMiddleware(debounceWindow: 60)
            let passthrough = PassthroughResponder()

            // A poll carrying the header must leave last_seen_at untouched.
            let pollReq = makeTestRequest(on: app, method: .GET, url: URI(path: "/admin/users-data"))
            pollReq.headers.add(name: UserActivityMiddleware.backgroundRefreshHeader, value: "1")
            pollReq.auth.login(try #require(try await APIUser.find(userID, on: app.db)))
            _ = try await middleware.respond(to: pollReq, chainingTo: passthrough)
            let afterPoll = try #require(try await APIUser.find(userID, on: app.db))
            #expect(
                abs(try #require(afterPoll.lastSeenAt).timeIntervalSince(stale)) < 1,
                "background-refresh poll must not refresh last_seen_at")

            // A normal request (no header) past the debounce must refresh it.
            let normalReq = makeTestRequest(on: app, method: .GET, url: URI(path: "/admin/users"))
            normalReq.auth.login(try #require(try await APIUser.find(userID, on: app.db)))
            _ = try await middleware.respond(to: normalReq, chainingTo: passthrough)
            let afterNormal = try #require(try await APIUser.find(userID, on: app.db))
            #expect(
                try #require(afterNormal.lastSeenAt).timeIntervalSince(stale) > 60,
                "a normal (non-poll) request must refresh last_seen_at")
        }
    }

    @Test func allAdminTabsShowVersionBanner() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            for path in ["/admin", "/admin/users", "/admin/storage", "/admin/audit", "/admin/alerts"] {
                try await app.asyncTest(
                    .GET, path,
                    beforeRequest: { req in
                        req.headers.add(name: .cookie, value: cookie)
                    },
                    afterResponse: { res in
                        #expect(res.status == .ok, "\(path) should render")
                        #expect(
                            String(buffer: res.body).contains("admin-version-banner"),
                            "\(path) should carry the version banner")
                    })
            }
        }
    }

    // MARK: - Audit log tab

    @Test func auditPageShowsEntriesWhenPresent() async throws {
        try await withApp(app) { _ in
            let entry = APIAuditLogEntry(
                actorUsername: "testuser",
                action: AuditAction.loginSuccess.rawValue,
                remoteAddr: "127.0.0.1"
            )
            try await entry.save(on: app.db)

            let cookie = try await loginAsAdmin("admin_routes", on: app)
            try await app.asyncTest(
                .GET, "/admin/audit",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("testuser"), "audit table should list the actor")
                    #expect(body.contains("auth.login_success"), "audit table should show the action code")
                    #expect(
                        !body.contains("No audit entries recorded yet."),
                        "empty-state should not appear when rows exist"
                    )
                })
        }
    }

    // MARK: - Storage tab per-assignment breakdown

    @Test func storageTabListsPerAssignmentFootprint() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("admin_routes", on: app)
            let course = try await makeCourse(code: "STG101", name: "Storage Course")
            let courseID = try course.requireID()
            _ = try await makeSetup(id: "setup_storage_bd", courseID: courseID)
            _ = try await makeAssignment(
                testSetupID: "setup_storage_bd", courseID: courseID, title: "Storage Breakdown Lab")
            let student = try await makeUser(username: "storage_bd_student", role: "student")
            _ = try await makeSubmission(
                id: "sub_storage_bd", setupID: "setup_storage_bd", userID: try student.requireID())

            try await app.asyncTest(
                .GET, "/admin/storage",
                beforeRequest: { req in
                    req.headers.add(name: .cookie, value: cookie)
                },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let body = String(buffer: res.body)
                    #expect(body.contains("By Assignment"))
                    #expect(body.contains("Storage Breakdown Lab"))
                    #expect(body.contains(">STG101<"))
                })
        }
    }

}

// MARK: - The admin-only gate and refusals

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
