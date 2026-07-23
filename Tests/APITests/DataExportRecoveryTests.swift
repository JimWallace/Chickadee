// Tests/APITests/DataExportRecoveryTests.swift
//
// Recovery for personal-data exports orphaned in `pending` by a server
// restart mid-generation (#557).  Generation runs in a detached background
// task, so a redeploy/crash while it is in flight leaves the `data_exports`
// row stuck `pending` forever — and the account page's status poll only
// stops when the row leaves `pending`, so the user is never told their data
// is ready or that it failed.  `failStalePendingDataExports` is the backstop
// that flips such rows to `failed` so the poll resolves and the request
// button reappears.

import Fluent
import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class DataExportRecoveryTests {

    let app: Application

    init() async throws {
        self.app = try await makeTestApp(prefix: "chickadee-dexp-recov")
    }

    /// Creates a persisted user (the `data_exports.user_id` FK cascades from
    /// `users.id`, so a real row is required) and returns its ID.
    private func makeUser() async throws -> UUID {
        let user = APIUser(
            username: "dexp-\(UUID().uuidString.prefix(8))",
            passwordHash: "x", role: "user")
        try await user.create(on: app.db)
        return try user.requireID()
    }

    /// Inserts an export row for `userID` in a chosen state and age.
    @discardableResult
    private func insertExport(
        userID: UUID,
        status: DataExportStatus,
        requestedAt: Date,
        zipPath: String? = nil
    ) async throws -> APIDataExport {
        let row = APIDataExport(userID: userID, requestedAt: requestedAt)
        row.setStatus(status)
        if status != .pending {
            row.completedAt = requestedAt.addingTimeInterval(1)
        }
        row.zipPath = zipPath
        try await row.create(on: app.db)
        return row
    }

    // MARK: - Sweep unit behaviour

    @Test func failStalePending_flipsInterruptedRowToFailed() async throws {
        try await withApp(app) { _ in
            let userID = try await makeUser()
            let requestedAt = Date().addingTimeInterval(-(dataExportStalePendingAge + 60))
            let row = try await insertExport(
                userID: userID, status: .pending, requestedAt: requestedAt)

            let failed = try await failStalePendingDataExports(on: app.db, logger: app.logger)
            #expect(failed == 1)

            let reloaded = try #require(try await APIDataExport.find(row.id, on: app.db))
            #expect(reloaded.statusValue == .failed)
            #expect(reloaded.completedAt != nil)
            #expect(reloaded.failureReason != nil)
            // requestedAt is the rate-limit / re-request ledger — never rewritten.
            #expect(reloaded.requestedAt == requestedAt)
        }
    }

    @Test func failStalePending_leavesFreshPendingUntouched() async throws {
        try await withApp(app) { _ in
            let userID = try await makeUser()
            // Just requested — a live generation task likely still owns it.
            let row = try await insertExport(
                userID: userID, status: .pending, requestedAt: Date())

            let failed = try await failStalePendingDataExports(on: app.db, logger: app.logger)
            #expect(failed == 0)

            let reloaded = try #require(try await APIDataExport.find(row.id, on: app.db))
            #expect(reloaded.statusValue == .pending)
        }
    }

    @Test func failStalePending_neverClobbersACompletedExport() async throws {
        try await withApp(app) { _ in
            // A slow-but-genuine export that completed long ago must not be
            // reaped even though its requestedAt is well past the threshold.
            let userID = try await makeUser()
            let requestedAt = Date().addingTimeInterval(-(dataExportStalePendingAge + 3600))
            let row = try await insertExport(
                userID: userID, status: .complete, requestedAt: requestedAt,
                zipPath: "/tmp/does-not-matter.zip")

            let failed = try await failStalePendingDataExports(on: app.db, logger: app.logger)
            #expect(failed == 0)

            let reloaded = try #require(try await APIDataExport.find(row.id, on: app.db))
            #expect(reloaded.statusValue == .complete)
            #expect(reloaded.zipPath == "/tmp/does-not-matter.zip")
        }
    }

    // MARK: - End-to-end: the stuck UI resolves

    @Test func stalePending_resolvesStatusPollAndReoffersRequest() async throws {
        try await withApp(app) { _ in
            let cookie = try await wrLoginAsStudent(on: app)
            let student = try await wrStudentUser(on: app)
            let userID = try student.requireID()

            // Simulate an export interrupted by a restart: a pending row older
            // than the staleness threshold with no live generation task.
            try await insertExport(
                userID: userID, status: .pending,
                requestedAt: Date().addingTimeInterval(-(dataExportStalePendingAge + 120)))

            // Before recovery: the poll keeps the page waiting forever.
            try await app.asyncTest(
                .GET, "/account/export/status",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.body.string.contains("\"status\":\"pending\""))
                })

            let failed = try await failStalePendingDataExports(on: app.db, logger: app.logger)
            #expect(failed == 1)

            // After recovery: the poll sees a terminal state (so account-export.js
            // reloads the page) ...
            try await app.asyncTest(
                .GET, "/account/export/status",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    #expect(res.body.string.contains("\"status\":\"failed\""))
                })

            // ... and the reloaded account page shows the failure notice and a
            // fresh request button.
            try await app.asyncTest(
                .GET, "/account",
                beforeRequest: { req in req.headers.add(name: .cookie, value: cookie) },
                afterResponse: { res in
                    #expect(res.status == .ok)
                    let page = res.body.string
                    #expect(page.contains("Your last export attempt failed"))
                    #expect(page.contains("Request data export"))
                })
        }
    }
}
