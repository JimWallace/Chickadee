// Tests/APITests/AdminOverviewPeopleTests.swift
//
// The admin Overview (runners and courses) and People pages in the shared row
// shape: the runner load pips, the rows fragment the poll swaps in, the course
// menus, and the auto-submitting role select.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AdminRunnerRowTests {

    private func worker(
        id: String = "r1", hostname: String = "", version: String = "", slots: Int = 4,
        assigned: Int = 0, processed: Int = 0, run: String? = nil, wait: String? = nil
    ) -> AdminWorkerRow {
        AdminWorkerRow(
            workerID: id, hostname: hostname, runnerVersion: version, maxConcurrentJobs: slots,
            lastActive: "2026-09-29T12:00:00Z", assignedJobs: assigned, jobsProcessed: processed,
            avgExecutionMs: nil, avgQueueWaitMs: nil, avgExecutionFormatted: run,
            avgQueueWaitFormatted: wait, isOffline: false)
    }

    @Test func pipsCountSlotsAndMarkBusyOnes() {
        #expect(AdminRunnerRow.loadPips(assigned: 2, slots: 4).map(\.state) == ["left", "left", "used", "used"])
        #expect(AdminRunnerRow.loadPips(assigned: 0, slots: 2).map(\.state) == ["used", "used"])
    }

    @Test func aFullRunnerReadsAmber() {
        #expect(AdminRunnerRow.loadPips(assigned: 4, slots: 4).map(\.state) == Array(repeating: "extra", count: 4))
        #expect(AdminRunnerRow.loadPips(assigned: 9, slots: 2).map(\.state) == ["extra", "extra"])
    }

    @Test func noSlotsMeansNoPips() {
        #expect(AdminRunnerRow.loadPips(assigned: 1, slots: 0).isEmpty)
        #expect(AdminRunnerRow(worker(slots: 0, assigned: 1)).hasSlots == false)
    }

    @Test func labelSaysIdleOrHowManyAreBusy() {
        #expect(AdminRunnerRow(worker(slots: 4, assigned: 2)).loadLabel == "2 of 4 busy")
        #expect(AdminRunnerRow(worker(slots: 4, assigned: 0)).loadLabel == "idle")
    }

    @Test func detailsLeaveOutWhatIsMissing() {
        let bare = AdminRunnerRow(worker(processed: 1))
        #expect(bare.detailsText == "1 job")
        let full = AdminRunnerRow(
            worker(hostname: "host-a", version: "v0.5", processed: 12, run: "14s", wait: "3s"))
        #expect(full.detailsText == "host-a · v0.5 · 12 jobs · avg run 14s · avg wait 3s")
    }
}

@Suite struct AdminRunnerDetailHelperTests {

    private func snapshot(_ active: Int, of max: Int, minutesAgo: Int) -> RunnerSnapshot {
        RunnerSnapshot(
            runnerID: "r", recordedAt: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)),
            activeJobs: active, maxJobs: max, availableCapacity: max - active, hostname: nil,
            runnerVersion: nil, lastPollAt: nil, lastHeartbeatAt: nil,
            serverAssignedJobCountSinceStart: nil)
    }

    @Test func barsRunOldestToNewestAndKeepAStubForIdle() {
        // Snapshots arrive newest first, as the query returns them.
        let chart = AdminRoutes.utilizationChart(
            snapshots: [
                snapshot(2, of: 2, minutesAgo: 1), snapshot(1, of: 2, minutesAgo: 2), snapshot(0, of: 2, minutesAgo: 3),
            ])
        #expect(chart.bars.map(\.state) == ["idle", "busy", "full"])
        #expect(chart.bars.map(\.heightPercent) == [2, 50, 100])
        #expect(chart.bars[1].title.hasSuffix("1 / 2 · 50%"))
    }

    @Test func aRunnerWithNoSlotsDrawsAnIdleStub() {
        let chart = AdminRoutes.utilizationChart(snapshots: [snapshot(0, of: 0, minutesAgo: 1)])
        #expect(chart.bars.map(\.state) == ["idle"])
        #expect(chart.labels.count == 1)
    }

    @Test func theAxisGetsAtMostFourLabels() {
        let many = (0..<50).map { snapshot($0 % 3, of: 2, minutesAgo: $0) }
        #expect(AdminRoutes.utilizationChart(snapshots: many).labels.count == 4)
        #expect(AdminRoutes.utilizationChart(snapshots: []).labels.isEmpty)
    }

    @Test func statusPillsFollowTheOutcome() {
        #expect(AdminRoutes.statusPill(for: "passed").tier == "open")
        #expect(AdminRoutes.statusPill(for: "failed").tier == "danger")
        #expect(AdminRoutes.statusPill(for: "error").tier == "danger")
        #expect(AdminRoutes.statusPill(for: "timeout") == ("Timed out", "preview"))
        #expect(AdminRoutes.statusPill(for: "weird").tier == "closed")
    }
}

@Suite(.serialized) final class AdminOverviewPeopleTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-overview")
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "overview_admin", password: "testpassword", role: "admin", on: app)
    }

    private func body(of path: String, cookie: String) async throws -> String {
        var html = ""
        try await app.asyncTest(
            .GET, path,
            beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
            afterResponse: { res in
                #expect(res.status == .ok)
                html = res.body.string
            })
        return html
    }

    @Test func runnerFragmentRendersTheRowShapeWithItsDataAttributes() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            await app.workerActivityStore.markActive(
                workerID: "pip-runner", hostname: "pip-host", runnerVersion: "v1",
                maxConcurrentJobs: 3, activeJobs: 0, lastHeartbeatAt: Date())
            let html = try await body(of: "/admin/runners?fragment=rows", cookie: cookie)
            #expect(!html.contains("<table"))
            #expect(html.contains("data-load=\"0\""))
            #expect(html.contains("data-max-jobs=\"3\""))
            #expect(html.contains("#i-server"))
            #expect(html.contains("pip-host · v1"))
            #expect(html.contains("<span class=\"pip\" data-state=\"used\"></span>"))
            #expect(html.contains(">idle<"))
        }
    }

    @Test func anOfflineRunnerShowsThePillInsteadOfPips() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            await app.workerActivityStore.markActive(
                workerID: "gone-runner", hostname: "", runnerVersion: "v1",
                maxConcurrentJobs: 2, activeJobs: 0,
                at: Date().addingTimeInterval(-10 * 60))
            let html = try await body(of: "/admin/runners?fragment=rows", cookie: cookie)
            #expect(html.contains("runner-row-offline"))
            #expect(html.contains(">Offline<"))
            #expect(!html.contains("class=\"pip\""))
        }
    }

    @Test func overviewPageAndFragmentRenderTheSameRows() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            await app.workerActivityStore.markActive(
                workerID: "same-runner", hostname: "", runnerVersion: "v2",
                maxConcurrentJobs: 2, activeJobs: 0, lastHeartbeatAt: Date())
            let page = try await body(of: "/admin", cookie: cookie)
            let fragment = try await body(of: "/admin/runners?fragment=rows", cookie: cookie)
            let row = "data-load=\"0\"\n                    data-max-jobs=\"2\""
            #expect(page.contains(row))
            #expect(fragment.contains(row))
            #expect(page.contains("id=\"workers-table\""))
            #expect(page.contains("data-poll-url=\"/admin/runners?fragment=rows\""))
        }
    }

    @Test func coursesGetAnAddMenuAndARowMenu() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeTestCourse(on: app, code: "OVW101", name: "Overview Course")
            let html = try await body(of: "/admin", cookie: cookie)
            #expect(html.contains("Create course"))
            #expect(html.contains("id=\"importCourseBtn\""))
            #expect(html.contains("Import course bundle"))
            #expect(html.contains("OVW101 — Overview Course"))
            #expect(html.contains("Export course bundle"))
            #expect(html.contains("Archive course"))
            // The archive confirmation keeps its wording.
            #expect(html.contains("Archive OVW101? 0 students lose access immediately."))
            #expect(!html.contains("id=\"courses-filter\""))
        }
    }

    @Test func peoplePageCountsUsersAndAdmins() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeTestUser(on: app, username: "plain_person", role: "user")
            let html = try await body(of: "/admin/users", cookie: cookie)
            let total = try await APIUser.query(on: app.db).count()
            let admins = try await APIUser.query(on: app.db).filter(\.$role == "admin").count()
            #expect(html.contains("\(total) users · \(admins) admins"))
        }
    }

    @Test func theRoleSelectSubmitsOnChangeAndHasNoSaveButton() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeTestUser(on: app, username: "role_person", role: "user")
            let html = try await body(of: "/admin/users-data?fragment=rows", cookie: cookie)
            #expect(html.contains("data-ck-submit-on-change"))
            #expect(html.contains("<option value=\"user\" selected>User</option>"))
            #expect(!html.contains(">Save<"))
            #expect(html.contains("state-select"))
        }
    }

    /// The Users page writes a bird for every person it lists on first view,
    /// and for nobody else: an MCP service account never opens an account
    /// page, so it gets no cosmetic row written (#1764).
    @Test func anMCPServiceAccountGetsNoAvatarWritten() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeTestUser(on: app, username: "svc_bird", role: "mcp")
            _ = try await makeTestUser(on: app, username: "human_bird", role: "user")
            _ = try await body(of: "/admin/users-data?fragment=rows", cookie: cookie)
            let service = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "svc_bird").first())
            let human = try #require(
                try await APIUser.query(on: app.db).filter(\.$username == "human_bird").first())
            #expect(service.avatarSpecJSON == nil)
            #expect(human.avatarSpecJSON != nil)
        }
    }

    @Test func anMCPServiceAccountGetsAPillInsteadOfASelect() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeTestUser(on: app, username: "svc_account", role: "mcp")
            let html = try await body(of: "/admin/users-data?fragment=rows", cookie: cookie)
            #expect(html.contains("MCP service"))
            #expect(!html.contains("for=\"role-\(try await userID("svc_account"))\""))
        }
    }

    @Test func everyPersonRowCarriesTheirOwnAvatarAndADeleteMenu() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try await makeTestUser(on: app, username: "avatar_person", role: "user")
            let html = try await body(of: "/admin/users-data?fragment=rows", cookie: cookie)
            #expect(html.contains("class=\"avatar"))
            #expect(html.contains("Delete user"))
            #expect(html.contains("Delete @avatar_person?"))
        }
    }

    private func userID(_ username: String) async throws -> String {
        let user = try #require(
            try await APIUser.query(on: app.db).filter(\.$username == username).first())
        return try user.requireID().uuidString
    }

    @Test func runnerDetailShowsTheChartTheHiddenTableAndTheJobs() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            try await RunnerSnapshot(
                runnerID: "detail-runner", recordedAt: Date().addingTimeInterval(-120),
                activeJobs: 2, maxJobs: 2, availableCapacity: 0, hostname: "h", runnerVersion: "v",
                lastPollAt: nil, lastHeartbeatAt: nil, serverAssignedJobCountSinceStart: nil
            ).save(on: app.db)
            try await RunnerSnapshot(
                runnerID: "detail-runner", recordedAt: Date().addingTimeInterval(-60),
                activeJobs: 0, maxJobs: 2, availableCapacity: 2, hostname: "h", runnerVersion: "v",
                lastPollAt: nil, lastHeartbeatAt: nil, serverAssignedJobCountSinceStart: nil
            ).save(on: app.db)
            await app.workerActivityStore.markActive(
                workerID: "detail-runner", hostname: "h", runnerVersion: "v",
                maxConcurrentJobs: 2, activeJobs: 0, lastHeartbeatAt: Date())
            let html = try await body(of: "/admin/runners/detail-runner", cookie: cookie)
            #expect(html.contains("Overview</a> › Runners"))
            #expect(html.contains("style=\"--bar-h:100%\""))
            #expect(html.contains("style=\"--bar-h:2%\""))
            #expect(html.contains("data-state=\"full\""))
            #expect(html.contains("<th scope=\"col\">Utilization %</th>"))
            // The ids the live poll writes to are still there.
            for id in [
                "runner-offline-badge", "runner-offline-status", "runner-last-active",
                "runner-hostname", "runner-version",
            ] {
                #expect(html.contains("id=\"\(id)\""))
            }
            #expect(html.contains("data-runner-id=\"detail-runner\""))
            // A fact with no value is left out, not shown as a dash.
            #expect(!html.contains("<dd>—</dd>"))
        }
    }

    @Test func anOfflineRunnerSaysHowLongItHasBeenSilent() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            try await RunnerSnapshot(
                runnerID: "quiet-runner", recordedAt: Date().addingTimeInterval(-600),
                activeJobs: 0, maxJobs: 1, availableCapacity: 1, hostname: "h", runnerVersion: "v",
                lastPollAt: nil, lastHeartbeatAt: nil, serverAssignedJobCountSinceStart: nil
            ).save(on: app.db)
            await app.workerActivityStore.markActive(
                workerID: "quiet-runner", hostname: "h", runnerVersion: "v",
                maxConcurrentJobs: 1, activeJobs: 0, at: Date().addingTimeInterval(-10 * 60))
            let html = try await body(of: "/admin/runners/quiet-runner", cookie: cookie)
            #expect(html.contains("<strong>No heartbeat for "))
            #expect(html.contains("None since it went offline."))
        }
    }
}
