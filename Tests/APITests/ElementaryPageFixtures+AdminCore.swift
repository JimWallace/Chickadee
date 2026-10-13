// Tests/APITests/ElementaryPageFixtures+AdminCore.swift
//
// The admin Overview, People and Health Alerts pages (the "AdminCore" group of
// the Leaf-to-Elementary migration), rendered for ElementaryPageGuardTests.

import Core
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {

    static var adminCorePages: [ElementaryPageFixture] {
        [adminPage, adminUsersPage, alertsPage]
    }

    // MARK: - Shared values

    static func runnerRow(id: String, slots: Int, assigned: Int, offline: Bool) -> AdminRunnerRow {
        AdminRunnerRow(
            AdminWorkerRow(
                workerID: id, hostname: "host-\(id)", runnerVersion: "v1", maxConcurrentJobs: slots,
                lastActive: "2026-10-01T10:00:00Z", assignedJobs: assigned, jobsProcessed: 12,
                avgExecutionMs: 1400, avgQueueWaitMs: nil, avgExecutionFormatted: "1.4s",
                avgQueueWaitFormatted: nil, isOffline: offline))
    }

    static func courseRow(code: String, term: AcademicTerm?) -> AdminCourseRow {
        AdminCourseRow(
            id: "c-\(code)", code: code, name: "Course \(code)", isArchived: false, enrollmentMode: "open",
            enrollmentCount: 30, assignmentCount: 4, submissionCount: 120, createdAt: "2026-09-01T00:00:00Z",
            brightspaceSyncEnabled: false
        ).withTerm(term)
    }

    static func userRow(
        id: String, displayName: String?, role: String, lastSeen: String?, avatar: AvatarAccessibility?,
        isCurrentUser: Bool = false
    ) -> AdminUserRow {
        var row = AdminUserRow(
            id: id, displayName: displayName, username: "user_\(id)", role: role,
            createdAt: "2026-09-01T00:00:00Z", lastSeenAt: lastSeen, isCurrentUser: isCurrentUser)
        if let avatar {
            row.avatar = AvatarPresentation(
                for: AvatarSpec.drawn(fromSeed: UInt64(id.count)), size: .roster, accessibility: avatar,
                isStaff: role == "admin")
        }
        return row
    }

    static var adminChart: ActivityChartData {
        ActivityChartData(
            window: "24h", generatedAt: "2026-10-01T10:00:00Z",
            buckets: [
                ActivityBucket(label: "09:00", startISO: "2026-10-01T09:00:00Z", count: 0),
                ActivityBucket(label: "10:00", startISO: "2026-10-01T10:00:00Z", count: 3),
            ])
    }

    /// A runner with busy slots, one that reports no slots, and one offline.
    static var adminWorkers: [AdminRunnerRow] {
        [
            runnerRow(id: "r1", slots: 4, assigned: 2, offline: false),
            runnerRow(id: "r2", slots: 0, assigned: 1, offline: false),
            runnerRow(id: "r3", slots: 2, assigned: 0, offline: true),
        ]
    }

    /// An admin with a name, a user with none (the viewer), and an MCP account.
    static var adminUsers: [AdminUserRow] {
        [
            userRow(id: "u1", displayName: "Ada", role: "admin", lastSeen: "2026-10-01T10:00:00Z", avatar: .decorative),
            userRow(
                id: "u2", displayName: nil, role: "user", lastSeen: nil, avatar: .labelled("@user_u2"),
                isCurrentUser: true),
            userRow(id: "u3", displayName: "", role: "mcp", lastSeen: nil, avatar: nil),
        ]
    }

    static var alertRules: [AdminAlertsRuleRow] {
        [
            AdminAlertsRuleRow(
                rule: "runner_offline", humanReadable: "A runner went offline", isFiring: true,
                lastFiredAt: "2026-10-01T10:00:00Z", thresholdText: "no heartbeat for 120s"),
            AdminAlertsRuleRow(
                rule: "queue_depth", humanReadable: "The queue backed up", isFiring: false, lastFiredAt: nil,
                thresholdText: "more than 50 pending"),
        ]
    }

    /// A failed page and an advisory firing, on two days.
    static var alertDays: [DayGroup<AdminAlertFiringRow>] {
        let records = [
            AlertFiringRecord(
                rule: "runner_offline", resolved: false, summary: "runner r1 offline",
                firedAt: "2026-10-01T10:00:00Z", paged: true, delivered: false, deliveryError: "HTTP 500"),
            AlertFiringRecord(
                rule: "queue_depth", resolved: true, summary: "queue backed up: 64 pending",
                firedAt: "2026-09-30T09:00:00Z", paged: false, delivered: false, deliveryError: nil),
        ]
        return DayGrouper.group(records.map(AdminAlertFiringRow.init), occurredAt: \.occurredAt)
    }

    // MARK: - Pages

    static var adminPage: ElementaryPageFixture {
        let chart = adminChart
        let workers = adminWorkers
        let fall = AcademicTerm(year: 2026, season: .fall)
        let many = (0..<12).map { courseRow(code: "CS\(100 + $0)", term: $0.isMultiple(of: 2) ? fall : nil) }
        func render(_ user: CurrentUserContext?, workers: [AdminRunnerRow], courses: [AdminCourseRow]) -> String {
            AdminPage(page: page(currentUser: user), workers: workers, courses: courses, activityChart: chart)
                .render()
        }
        return ElementaryPageFixture(
            typeName: "AdminPage",
            archetype: .adminTabbed,
            renders: [
                render(nil, workers: [], courses: []),
                render(signedInAdmin, workers: workers, courses: [courseRow(code: "CS135", term: fall)]),
                render(signedInAdmin, workers: workers, courses: many),
            ]
        )
    }

    static var adminUsersPage: ElementaryPageFixture {
        let users = adminUsers
        func render(_ users: [AdminUserRow]) -> String {
            AdminUsersPage(
                page: page(currentUser: signedInAdmin), users: users, userCount: users.count,
                adminCount: users.filter { $0.role == "admin" }.count
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminUsersPage",
            archetype: .adminTabbed,
            renders: [render([]), render(users)]
        )
    }

    static var alertsPage: ElementaryPageFixture {
        let rules = alertRules
        let days = alertDays
        func render(
            enabled: Bool, fromEnvironment: Bool, lastDelivery: (iso: String, result: String)?,
            days: [DayGroup<AdminAlertFiringRow>], flash: FlashMessages = FlashMessages()
        ) -> String {
            AlertsPage(
                page: page(currentUser: signedInAdmin), flash: flash, enabled: enabled,
                webhookURL: enabled ? "https://hooks.example/services/x" : "",
                webhookURLFromEnvironment: fromEnvironment,
                rules: rules, webhookDisplay: enabled ? "hooks.example/services/x" : "Not set",
                lastDelivery: lastDelivery, firingDays: days
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AlertsPage",
            archetype: .adminTabbed,
            renders: [
                render(enabled: false, fromEnvironment: false, lastDelivery: nil, days: []),
                render(
                    enabled: true, fromEnvironment: true,
                    lastDelivery: (iso: "2026-10-01T10:00:00Z", result: "Delivery failed"), days: days,
                    flash: FlashMessages(success: "Test alert sent.")),
            ],
            isExemplar: true
        )
    }
}
