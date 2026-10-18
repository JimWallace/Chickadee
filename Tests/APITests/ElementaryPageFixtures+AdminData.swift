// Tests/APITests/ElementaryPageFixtures+AdminData.swift
//
// The admin Data pages (storage, retention, audit log), for
// ElementaryPageGuardTests.

import Elementary
import Foundation

@testable import APIServer

extension ElementaryPageFixtures {
    static var adminDataPages: [ElementaryPageFixture] {
        [adminAuditPage, adminRetentionPage, adminStoragePage]
    }

    static var adminAuditPage: ElementaryPageFixture {
        func row(_ day: Int, targetType: String?, targetID: String?, metadata: String) -> AdminAuditRow {
            AdminAuditRow(
                timestamp: "2026-10-0\(day) 10:00", timestampISO: "2026-10-0\(day)T14:00:00Z", actor: "ada",
                category: "Authentication", label: "Signed in", action: "auth.login", targetType: targetType,
                targetID: targetID, metadata: metadata, remoteAddr: "10.0.0.1", outcome: "ok",
                outcomeTier: AuditOutcome.ok.tierClass,
                occurredAt: Date(timeIntervalSince1970: 1_790_000_000 - Double(day) * 86_400),
                clockText: "10:00:00", categoryKey: "auth", tileKind: "slides", iconHref: "#i-key")
        }
        let rows = [
            row(1, targetType: "course", targetID: "c1", metadata: "{\"code\": \"CS135\"}"),
            row(2, targetType: nil, targetID: nil, metadata: ""),
        ]
        let options = [
            SelectOption(value: "auth.login", label: "Authentication — Signed in", selected: true),
            SelectOption(value: "auth.logout", label: "Authentication — Signed out", selected: false),
        ]
        func render(_ rows: [AdminAuditRow], filtered: Bool) -> String {
            AdminAuditPage(
                page: page(currentUser: signedInAdmin),
                days: DayGrouper.group(rows, occurredAt: \.occurredAt), actionOptions: options,
                filterActor: filtered ? "ada" : "", filtered: filtered, matchCount: rows.count
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminAuditPage",
            archetype: .adminTabbed,
            renders: [render(rows, filtered: false), render([], filtered: true), render([], filtered: false)]
        )
    }

    static var adminRetentionPage: ElementaryPageFixture {
        let rows = [
            AdminRetentionRow(
                id: "c1", code: "CS135", name: "Design", termLabel: "Fall 2025", archivedAt: "Jan 1, 2026",
                archivedAtISO: "2026-01-01T00:00:00Z", purgeEligibleAt: "Jan 1, 2027",
                purgeEligibleAtISO: "2027-01-01T00:00:00Z", submissionCount: 12, isDeletable: true),
            AdminRetentionRow(
                id: "c2", code: "CS136", name: "Algorithms", termLabel: nil, archivedAt: "—", archivedAtISO: "",
                purgeEligibleAt: "—", purgeEligibleAtISO: "", submissionCount: 0, isDeletable: false),
        ]
        func render(_ rows: [AdminRetentionRow], flash: FlashMessages = FlashMessages()) -> String {
            AdminRetentionPage(
                page: page(currentUser: signedInAdmin), flash: flash, retentionDays: 365, rows: rows
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminRetentionPage",
            archetype: .adminTabbed,
            renders: [render(rows, flash: FlashMessages(success: "Course restored.")), render([])]
        )
    }

    static var adminStoragePage: ElementaryPageFixture {
        let assignments = [
            AdminAssignmentStorageRow(
                assignmentTitle: "Lab 1", courseCode: "CS135", testSuiteFormatted: "1.0 MB",
                submissionsFormatted: "3.0 MB", submissionCount: 12, totalFormatted: "4.0 MB",
                testSuiteBytes: 1_000_000, submissionsBytes: 3_000_000, totalBytes: 4_000_000),
            AdminAssignmentStorageRow(
                assignmentTitle: "Lab 2", courseCode: "CS136", testSuiteFormatted: "10 KB",
                submissionsFormatted: "0 B", submissionCount: 0, totalFormatted: "10 KB",
                testSuiteBytes: 10_000, submissionsBytes: 0, totalBytes: 10_000),
        ]
        let libraries = [
            AdminCourseLibraryStorageRow(
                courseKey: "HLTH230-W27", datasetCount: 2, versionCount: 3, bytes: 90_000, formatted: "90 KB")
        ]
        func render(
            _ assignments: [AdminAssignmentStorageRow], disk: DiskSpace?,
            libraries: [AdminCourseLibraryStorageRow] = []
        ) -> String {
            let storage = AdminStorageContext(
                rows: [
                    AdminStorageRow(label: "Database", formatted: "2.0 MB"),
                    AdminStorageRow(label: "Submissions", formatted: "3.0 MB"),
                ],
                totalFormatted: "5.0 MB", dbBackend: "sqlite", assignments: assignments, totalBytes: 5_000_000,
                disk: disk, libraries: libraries)
            return AdminStoragePage(
                page: page(currentUser: signedInAdmin), storage: storage,
                assignmentRows: AdminStorageShareRow.rows(from: assignments, totalBytes: storage.totalBytes)
            ).render()
        }
        return ElementaryPageFixture(
            typeName: "AdminStoragePage",
            archetype: .adminTabbed,
            renders: [
                render(assignments, disk: DiskSpace(freeBytes: 25_000_000_000, totalBytes: 93_000_000_000)),
                render([], disk: nil),
                render(assignments, disk: nil, libraries: libraries),
            ]
        )
    }
}
