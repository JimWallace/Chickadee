// Tests/APITests/Admin/DataExportRetentionReaperTests.swift
//
// `reapExpiredDataExports` (#557) with the clock passed in. It deletes every
// export row older than the retention window, in any state, with its zip. It
// keeps a fresh row and its zip, and it keeps an expired row whose zip it
// could not delete, so the next sweep tries the file again. The periodic
// monitor runs the same sweep. `DataExportRoutesTests` covers one expired
// complete export made through the routes.

import ChickadeeTestSupport
import Fluent
import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) final class DataExportRetentionReaperTests {

    let app: Application
    private let scratch: URL

    init() async throws {
        app = try await makeTestApp(prefix: "chickadee-dexp-reaper")
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-dexp-reaper-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    deinit {
        // Give the owner back write access first, so the locked directory of
        // the macOS case can be removed.
        try? FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o755)],
            ofItemAtPath: scratch.appendingPathComponent("locked").path)
        try? FileManager.default.removeItem(at: scratch)
    }

    /// Saves one export row for a new user, requested at `requestedAt`.
    @discardableResult
    private func makeExport(
        username: String, requestedAt: Date, status: DataExportStatus, zipPath: String? = nil
    ) async throws -> APIDataExport {
        let user = try await makeTestUser(on: app, username: username)
        let export = APIDataExport(userID: try user.requireID(), requestedAt: requestedAt)
        export.setStatus(status)
        export.zipPath = zipPath
        try await export.save(on: app.db)
        return export
    }

    /// Writes a small file in the scratch directory and returns its path.
    private func makeZip(named name: String) throws -> String {
        let path = scratch.appendingPathComponent(name).path
        #expect(FileManager.default.createFile(atPath: path, contents: Data("zip".utf8)))
        return path
    }

    private func exportExists(_ export: APIDataExport) async throws -> Bool {
        try await APIDataExport.find(export.requireID(), on: app.db) != nil
    }

    /// A path that exists and that this process cannot delete. On Linux the
    /// tests may run as root, which a directory mode does not stop, so the
    /// path is a procfs file: procfs refuses an unlink from any user. On
    /// macOS the tests run as the developer, so a read-only parent directory
    /// is enough.
    private func undeletablePath() throws -> String {
        #if os(Linux)
        return "/proc/self/status"
        #else
        let locked = scratch.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let path = locked.appendingPathComponent("held.zip").path
        #expect(FileManager.default.createFile(atPath: path, contents: Data("zip".utf8)))
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: 0o555)], ofItemAtPath: locked.path)
        return path
        #endif
    }

    @Test func expiredRowsGoInEveryStateAndFreshRowsStay() async throws {
        try await withApp(app) { app in
            let now = Date()
            let expired = now.addingTimeInterval(-dataExportRetentionMaxAge - 60)
            let fresh = now.addingTimeInterval(-dataExportRetentionMaxAge + 60)

            let expiredZip = try makeZip(named: "expired.zip")
            let freshZip = try makeZip(named: "fresh.zip")
            let expiredComplete = try await makeExport(
                username: "dexp_old_complete", requestedAt: expired, status: .complete, zipPath: expiredZip)
            let expiredFailed = try await makeExport(
                username: "dexp_old_failed", requestedAt: expired, status: .failed)
            let expiredPendingMissingZip = try await makeExport(
                username: "dexp_old_pending", requestedAt: expired, status: .pending,
                zipPath: scratch.appendingPathComponent("never-written.zip").path)
            let freshComplete = try await makeExport(
                username: "dexp_new_complete", requestedAt: fresh, status: .complete, zipPath: freshZip)

            try await reapExpiredDataExports(on: app.db, logger: app.logger, now: now)

            #expect(try await !exportExists(expiredComplete))
            #expect(try await !exportExists(expiredFailed))
            #expect(try await !exportExists(expiredPendingMissingZip))
            #expect(!FileManager.default.fileExists(atPath: expiredZip))

            #expect(try await exportExists(freshComplete))
            #expect(FileManager.default.fileExists(atPath: freshZip))
            #expect(try await APIDataExport.query(on: app.db).count() == 1)
        }
    }

    @Test func aZipThatCannotBeDeletedKeepsItsRowForTheNextSweep() async throws {
        try await withApp(app) { app in
            let now = Date()
            let expired = now.addingTimeInterval(-dataExportRetentionMaxAge - 60)
            let heldPath = try undeletablePath()
            let otherZip = try makeZip(named: "other.zip")
            let held = try await makeExport(
                username: "dexp_held", requestedAt: expired, status: .complete, zipPath: heldPath)
            let other = try await makeExport(
                username: "dexp_other", requestedAt: expired, status: .complete, zipPath: otherZip)

            try await reapExpiredDataExports(on: app.db, logger: app.logger, now: now)

            // The row stays, so its path is not forgotten.
            let kept = try #require(try await APIDataExport.find(held.requireID(), on: app.db))
            #expect(kept.zipPath == heldPath)
            #expect(FileManager.default.fileExists(atPath: heldPath))
            // One file the reaper cannot delete does not stop the others.
            #expect(try await !exportExists(other))
            #expect(!FileManager.default.fileExists(atPath: otherZip))
        }
    }

    @Test func theMonitorSweepDeletesAnExpiredExport() async throws {
        try await withApp(app) { app in
            let expired = Date().addingTimeInterval(-dataExportRetentionMaxAge - 60)
            let fresh = Date()
            let old = try await makeExport(username: "dexp_monitor_old", requestedAt: expired, status: .failed)
            let current = try await makeExport(
                username: "dexp_monitor_new", requestedAt: fresh, status: .pending)

            let monitor = app.dataExportReaperMonitor
            #expect(monitor.name == "Data-export reaper")
            monitor.start(application: app)
            var gone = false
            for _ in 0..<200 {
                if try await !exportExists(old) {
                    gone = true
                    break
                }
                try await Task.sleep(for: .milliseconds(25))
            }
            await monitor.stop()

            #expect(gone)
            #expect(try await exportExists(current))
        }
    }
}
