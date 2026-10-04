// Tests/APITests/AdminDataTests.swift
//
// The admin Data pages in the shared row shape: Storage (a share bar per
// assignment, server order kept) and Retention (a ⋯ menu only where there is
// something to put in it).

import Core
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AdminStorageShareRowTests {

    private func row(_ title: String, bytes: Int, count: Int = 1) -> AdminAssignmentStorageRow {
        AdminAssignmentStorageRow(
            assignmentTitle: title, courseCode: "C1", testSuiteFormatted: "1 KB",
            submissionsFormatted: "2 KB", submissionCount: count,
            totalFormatted: humanReadableBytes(bytes), testSuiteBytes: 0, submissionsBytes: 0,
            totalBytes: bytes)
    }

    @Test func theLargestRowFillsTheBarAndTheRestReadAgainstIt() {
        let rows = AdminStorageShareRow.rows(
            from: [row("a", bytes: 800), row("b", bytes: 400), row("c", bytes: 0)], totalBytes: 2000)
        #expect(rows.map(\.barPercent) == [100, 50, 0])
    }

    @Test func shareIsAPercentOfTheTotalOnDisk() {
        let rows = AdminStorageShareRow.rows(
            from: [row("a", bytes: 500), row("b", bytes: 10)], totalBytes: 1000)
        #expect(rows.map(\.shareLabel) == ["50%", "1%"])
        let tiny = AdminStorageShareRow.rows(from: [row("t", bytes: 1)], totalBytes: 1000)
        #expect(tiny.first?.shareLabel == "<1%")
        #expect(tiny.first?.barPercent == 100)
    }

    @Test func anUnknownTotalFallsBackToTheSumOfTheRows() {
        let rows = AdminStorageShareRow.rows(
            from: [row("a", bytes: 300), row("b", bytes: 100)], totalBytes: 0)
        #expect(rows.map(\.shareLabel) == ["75%", "25%"])
    }

    @Test func shareLabelsOfAllRowsNeverExceedAHundredPercent() {
        let rows = AdminStorageShareRow.rows(
            from: [row("a", bytes: 330), row("b", bytes: 330), row("c", bytes: 340)], totalBytes: 1000)
        let sum = rows.compactMap { Int($0.shareLabel.dropLast()) }.reduce(0, +)
        #expect(sum <= 101)
    }

    @Test func detailsLeaveNoRoomForADash() {
        let shown = AdminStorageShareRow.rows(from: [row("a", bytes: 10, count: 1)], totalBytes: 10)
        #expect(shown.first?.detailsText == "suite 1 KB · submissions 2 KB · 1 submission")
    }
}

@Suite(.serialized) final class AdminDataTests {
    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-admin-data")
    }

    @Test func storageShowsAShareBarPerAssignmentAndNoSorter() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("data_admin", on: app)
            let course = try await makeTestCourse(on: app, code: "SHR101", name: "Share")
            let courseID = try course.requireID()
            let setup = try await makeTestSetup(on: app, id: "setup_share", courseID: courseID)
            try await APIAssignment(
                testSetupID: try #require(setup.id), title: "Shared Lab", isOpen: false,
                courseID: courseID
            ).save(on: app.db)
            let html = try await getHTML("/admin/storage", cookie: cookie, on: app)
            #expect(html.contains("Shared Lab"))
            #expect(html.contains(">SHR101<"))
            #expect(html.contains("class=\"share-bar\" style=\"--share:"))
            #expect(html.contains("Largest first"))
            #expect(!html.contains("sortable-table.js"))
            #expect(!html.contains("storage-meta"))
        }
    }

    @Test func retentionOffersTheDeleteMenuOnlyWhenTheCourseIsDeletable() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("data_admin", on: app)
            let eligible = try await makeTestCourse(
                on: app, code: "RETMENUELIG", name: "Eligible", archived: true)
            eligible.archivedAt = Date().addingTimeInterval(-900 * 86_400)
            try await eligible.save(on: app.db)
            let pending = try await makeTestCourse(
                on: app, code: "RETMENUPEND", name: "Pending", archived: true)
            pending.archivedAt = Date()
            try await pending.save(on: app.db)

            let html = try await getHTML("/admin/retention", cookie: cookie, on: app)
            #expect(html.contains("Eligible to delete"))
            #expect(html.contains("Delete course permanently"))
            // The menu is one per deletable row; the other row holds a spacer.
            #expect(html.components(separatedBy: "row-menu-spacer").count - 1 == 1)
            #expect(html.components(separatedBy: "More actions for RETMENU").count - 1 == 1)
            #expect(html.contains("2 archived · 1 eligible to delete"))
            // The restore confirmation keeps its wording.
            #expect(html.contains("Restore RETMENUPEND? Students regain access immediately."))
        }
    }

    @Test func retentionKeepsServerOrderEligibleFirst() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("data_admin", on: app)
            let pending = try await makeTestCourse(
                on: app, code: "RETORDAAA", name: "Pending", archived: true)
            pending.archivedAt = Date()
            try await pending.save(on: app.db)
            let eligible = try await makeTestCourse(
                on: app, code: "RETORDZZZ", name: "Eligible", archived: true)
            eligible.archivedAt = Date().addingTimeInterval(-900 * 86_400)
            try await eligible.save(on: app.db)
            let html = try await getHTML("/admin/retention", cookie: cookie, on: app)
            let eligibleAt = try #require(html.range(of: ">RETORDZZZ<"))
            let pendingAt = try #require(html.range(of: ">RETORDAAA<"))
            #expect(eligibleAt.lowerBound < pendingAt.lowerBound)
            #expect(!html.contains("sortable-table"))
        }
    }
}
