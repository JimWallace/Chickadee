// Tests/APITests/AdminLogsTests.swift
//
// The two admin log surfaces: Health alerts (rules and firings) and the Audit
// log, and the day grouping they share with the instructor Activity page.

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

private struct StampedRow: Encodable, Sendable, Equatable {
    let id: Int
    let at: Date
}

@Suite struct DayGrouperTests {
    private var zone: TimeZone { TimeZone(identifier: "America/Toronto") ?? .current }

    private func date(_ iso: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: iso))
    }

    @Test func labelsTodayYesterdayAndOlderDays() throws {
        let now = try date("2026-09-30T18:00:00Z")
        let rows = [
            StampedRow(id: 1, at: try date("2026-09-30T15:00:00Z")),
            StampedRow(id: 2, at: try date("2026-09-29T15:00:00Z")),
            StampedRow(id: 3, at: try date("2026-09-26T15:00:00Z")),
        ]
        let groups = DayGrouper.group(rows, occurredAt: \.at, now: now, timeZone: zone)
        #expect(groups.map(\.label) == ["Today", "Yesterday", "Sep 26"])
        #expect(groups.map { $0.rows.map(\.id) } == [[1], [2], [3]])
    }

    @Test func cutsDaysAtLocalMidnightNotUTC() throws {
        // 03:30 UTC on Sep 30 is 23:30 on Sep 29 in Toronto, so it is the
        // same day as 20:00 UTC on Sep 29, and a different day from 15:00 UTC
        // on Sep 30.
        let now = try date("2026-09-30T18:00:00Z")
        let rows = [
            StampedRow(id: 1, at: try date("2026-09-30T15:00:00Z")),
            StampedRow(id: 2, at: try date("2026-09-30T03:30:00Z")),
            StampedRow(id: 3, at: try date("2026-09-29T20:00:00Z")),
        ]
        let groups = DayGrouper.group(rows, occurredAt: \.at, now: now, timeZone: zone)
        #expect(groups.map { $0.rows.map(\.id) } == [[1], [2, 3]])
        #expect(groups.map(\.label) == ["Today", "Yesterday"])
    }

    @Test func noRowsMeansNoGroups() {
        #expect(DayGrouper.group([StampedRow](), occurredAt: \.at).isEmpty)
    }
}

@Suite struct AdminAlertsPresentationTests {
    private let config = ServerHealthAlertConfiguration.default

    @Test func everyRuleSaysWhatItFiresOn() {
        for rule in HealthRule.allCases {
            #expect(!rule.thresholdText(config).isEmpty, "\(rule.rawValue) has no threshold text")
        }
    }

    @Test func thresholdTextReadsTheLiveConfiguration() {
        #expect(HealthRule.runnerOffline.thresholdText(config) == "no runner heartbeat for 300s")
        #expect(HealthRule.queueBackedUp.thresholdText(config) == "≥ 25 pending or oldest > 600s")
        #expect(
            HealthRule.errorRateSpike.thresholdText(config)
                == "≥ 30% errors and timeouts in the last 50 jobs")
        #expect(HealthRule.databaseUnreachable.thresholdText(config) == "SELECT 1 fails")
    }

    @Test func aWebhookIsShortenedFromTheMiddle() {
        let url = "https://hooks.slack.com/services/T04ABCDEF/B07GHIJKL/xoxbSECRETSECRETSECRET"
        let shown = AdminAlertsPresentation.webhookDisplay(url)
        #expect(shown.hasPrefix("hooks.slack.com/"))
        #expect(shown.contains("…"))
        #expect(shown.hasSuffix("ECRET"))
        #expect(shown.count <= 44)
        #expect(AdminAlertsPresentation.webhookDisplay("http://short.example/x") == "short.example/x")
        #expect(AdminAlertsPresentation.webhookDisplay("  ") == "Not set")
    }

    @Test func aFiringSaysHowItWasDelivered() {
        func record(paged: Bool, delivered: Bool, error: String? = nil) -> AlertFiringRecord {
            AlertFiringRecord(
                rule: "runnerOffline", resolved: false, summary: "s",
                firedAt: "2026-09-30T12:00:00Z", paged: paged, delivered: delivered,
                deliveryError: error)
        }
        #expect(AdminAlertFiringRow(record(paged: false, delivered: false)).deliveryText == "advisory, not paged")
        #expect(AdminAlertFiringRow(record(paged: true, delivered: true)).deliveryText == "Delivered")
        let failed = AdminAlertFiringRow(record(paged: true, delivered: false, error: "timed out"))
        #expect(failed.deliveryText == "Delivery failed: timed out")
        #expect(failed.deliveryFailed)
    }

    @Test func lastDeliverySkipsAdvisoryFirings() {
        let advisory = AlertFiringRecord(
            rule: "runnerVersionSkew", resolved: false, summary: "a", firedAt: "2026-09-30T13:00:00Z",
            paged: false, delivered: false, deliveryError: nil)
        let paged = AlertFiringRecord(
            rule: "runnerOffline", resolved: false, summary: "p", firedAt: "2026-09-30T12:00:00Z",
            paged: true, delivered: true, deliveryError: nil)
        let records = [advisory, paged]
        let rows = records.map(AdminAlertFiringRow.init)
        let last = AdminAlertsPresentation.lastDelivery(rows, records: records)
        #expect(last?.iso == "2026-09-30T12:00:00Z")
        #expect(last?.result == "Delivered")
        #expect(AdminAlertsPresentation.lastDelivery([], records: []) == nil)
    }
}

@Suite struct AuditCategoryTileTests {
    @Test func auditCategoriesPickTheirTile() {
        #expect(AuditCategoryTile.tile(forCategory: AuditCategory.authentication.rawValue).icon == "#i-key")
        #expect(AuditCategoryTile.tile(forCategory: AuditCategory.mcp.rawValue).icon == "#i-cpu")
        #expect(AuditCategoryTile.tile(forCategory: AuditCategory.users.rawValue).icon == "#i-shield")
        #expect(AuditCategoryTile.tile(forCategory: "Other").key == "other")
    }
}

@Suite(.serialized) final class AdminLogsTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-logs")
    }

    private func loginAsAdmin() async throws -> String {
        try await loginUser(username: "logs_admin", password: "testpassword", role: "admin", on: app)
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

    @Test func alertsPageShowsTheNoticeRulesAndNoPayloadDisclosure() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            _ = try? await app.serverHealthAlertMonitor.dispatchTestAlert(application: app)
            let html = try await body(of: "/admin/alerts", cookie: cookie)
            #expect(html.contains("<strong>Alerting is off.</strong>"))
            #expect(html.contains("tier-closed\">Disabled<"))
            #expect(html.contains("Edit webhook"))
            #expect(html.contains("action=\"/admin/alerts/config\""))
            #expect(html.contains("Send test alert"))
            #expect(html.contains("no runner heartbeat for 300s"))
            #expect(html.contains("Runner offline"))
            // The Payload disclosure is gone; delivery lives on the row.
            #expect(!html.contains("<summary>Payload</summary>"))
            #expect(html.contains("Test alert from /admin/alerts"))
            #expect(html.contains("Delivered") || html.contains("Delivery failed"))
            #expect(html.contains("<strong>Today</strong>"))
        }
    }

    @Test func alertsPageWithNoFiringsKeepsItsEmptyState() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin()
            let html = try await body(of: "/admin/alerts", cookie: cookie)
            #expect(html.contains("No alerts have fired since startup."))
        }
    }

    @Test func auditPageGroupsByDayAndKeepsEveryPayloadField() async throws {
        try await withApp(app) { _ in
            let entry = APIAuditLogEntry(
                actorUsername: "audit_actor", action: AuditAction.loginSuccess.rawValue,
                targetType: "user", targetID: "abc", remoteAddr: "10.0.0.9", metadata: "{\"k\":\"v\"}")
            try await entry.save(on: app.db)
            let cookie = try await loginAsAdmin()
            let html = try await body(of: "/admin/audit", cookie: cookie)
            #expect(html.contains("<strong>Today</strong>"))
            #expect(html.contains("class=\"log-entry\""))
            for label in ["Category", "Target", "Remote", "Metadata"] {
                #expect(html.contains("<dt>\(label)</dt>"))
            }
            #expect(html.contains("10.0.0.9"))
            #expect(html.contains("<code>auth.login_success</code>"))
            #expect(html.contains("#i-key"))
            // A log stays unsortable, and the old Filter button is gone.
            #expect(!html.contains("sortable-table.js"))
            #expect(!html.contains("sortable-table\""))
            #expect(!html.contains("class=\"btn\">Filter</button>"))
            #expect(html.contains("Showing the newest "))
        }
    }

    @Test func auditFiltersRoundTripAndClearShowsOnlyWhenFiltered() async throws {
        try await withApp(app) { _ in
            try await APIAuditLogEntry(
                actorUsername: "someone_else", action: AuditAction.loginSuccess.rawValue,
                remoteAddr: "127.0.0.1"
            ).save(on: app.db)
            let cookie = try await loginAsAdmin()
            let plain = try await body(of: "/admin/audit", cookie: cookie)
            #expect(!plain.contains(">Clear</a>"))
            let filtered = try await body(
                of: "/admin/audit?action=auth.login_success&actor=someone", cookie: cookie)
            #expect(filtered.contains(">Clear</a>"))
            #expect(filtered.contains("value=\"someone\""))
            #expect(filtered.contains("<option value=\"auth.login_success\" selected>"))
            let none = try await body(of: "/admin/audit?actor=nobody_at_all", cookie: cookie)
            #expect(none.contains("No audit entries match this filter."))
        }
    }

}
