// Tests/APITests/Pages/SharedPollerRegionTests.swift
//
// The account page's export state and the admin runner page's live header
// refresh through `table-poll.js`, the one poller (#3007). Each page renders
// a polled region, and its fragment endpoint renders the same view alone.

import Elementary
import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite struct AccountExportStateRegionTests {

    @Test func aPendingExportNamesItsStateAndIsNotFinal() {
        let html = AccountExportStateRegion(isPending: true, requestedAtDisplay: "Nov 13, 2026 at 9:00 PM")
            .render()
        #expect(html.contains("id=\"export-pending\""))
        #expect(html.contains("Requested Nov 13, 2026 at 9:00 PM."))
        #expect(!html.contains("data-export-final"))
    }

    @Test func aFinishedExportIsFinalAndLinksBackToTheAccountPage() {
        let html = AccountExportStateRegion(isPending: false, requestedAtDisplay: nil).render()
        #expect(html.contains("data-export-final=\"true\""))
        #expect(html.contains("href=\"/account\""))
        #expect(!html.contains("export-pending"))
    }
}

@Suite(.serialized, .timeLimit(.minutes(2))) final class SharedPollerRouteTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-shared-poller")
    }

    @Test func thePendingExportIsAPolledRegionAndItsFragmentMatches() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let row = APIDataExport(userID: try student.requireID(), requestedAt: Date())
            row.setStatus(.pending)
            try await row.create(on: app.db)

            let page = try await getHTML("/account", cookie: cookie, on: app)
            #expect(page.contains("data-poll-url=\"/account/export/status?fragment=state\""))
            #expect(page.contains("data-poll-swap=\"region\""))
            #expect(page.contains("/table-poll.js"))
            #expect(!page.contains("/account-export.js"))

            let pending = try await getHTML("/account/export/status?fragment=state", cookie: cookie, on: app)
            #expect(pending.contains("id=\"export-pending\""))
            #expect(!pending.contains("<html"))

            row.setStatus(.complete)
            row.completedAt = Date()
            try await row.save(on: app.db)
            let done = try await getHTML("/account/export/status?fragment=state", cookie: cookie, on: app)
            #expect(done.contains("data-export-final=\"true\""))

            // The JSON status is unchanged for any other request.
            let json = try await getHTML("/account/export/status", cookie: cookie, on: app)
            #expect(json.contains("\"status\":\"complete\""))
        }
    }

    @Test func theRunnerHeaderIsAPolledRegionAndItsFragmentMatches() async throws {
        try await withApp(app) { _ in
            let cookie = try await loginAsAdmin("poller_admin", on: app)
            await app.workerActivityStore.markActive(
                workerID: "poll-runner", hostname: "grader.example", runnerVersion: "0.5.9",
                maxConcurrentJobs: 2, activeJobs: 0, lastHeartbeatAt: Date())

            let page = try await getHTML("/admin/runners/poll-runner", cookie: cookie, on: app)
            #expect(page.contains("data-poll-url=\"/admin/runners/poll-runner?fragment=status\""))
            #expect(page.contains("/table-poll.js"))

            let fragment = try await getHTML("/admin/runners/poll-runner?fragment=status", cookie: cookie, on: app)
            #expect(!fragment.contains("<html"))
            #expect(fragment.contains("<span id=\"runner-hostname\">grader.example</span>"))
            #expect(fragment.contains("<span id=\"runner-version\">0.5.9</span>"))
            #expect(fragment.contains("id=\"runner-last-active\""))
            #expect(fragment.contains("id=\"runner-offline-status\""))
            // The heading is fixed chrome, outside the region.
            #expect(!fragment.contains("runner-offline-badge"))
        }
    }
}
