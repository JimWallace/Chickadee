import Core
import Fluent
import Foundation
import NIOFoundationCompat
import Testing
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
