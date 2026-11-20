// Tests/APITests/Admin/ServerHealthAlertMonitorTests.swift
//
// The monitor actor around the pure alert rules: which webhook URL wins, what
// a sweep records when a page is delivered or refused, the cooldown and the
// resolve message through a real sweep, the cap on the recent-firings buffer,
// and the boot stamp that the version-skew grace reads. `ServerHealthAlertTests`
// covers the pure transition function; these tests drive the actor that uses
// it. No test here makes a network call: a refused page uses a webhook URL
// whose scheme `WebhookNotifier` rejects before it sends.

import Foundation
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct ServerHealthAlertMonitorTests {

    /// A scheme that `WebhookNotifier` refuses before any request, so a
    /// delivery fails without the network.
    private let refusedWebhookURL = "ftp://alerts.invalid/hook"

    private func configuration(
        enabled: Bool = false,
        cooldownSeconds: TimeInterval = 1800,
        webhookURL: String? = nil
    ) -> ServerHealthAlertConfiguration {
        let base = ServerHealthAlertConfiguration.default
        return ServerHealthAlertConfiguration(
            enabled: enabled,
            checkIntervalSeconds: base.checkIntervalSeconds,
            cooldownSeconds: cooldownSeconds,
            runnerOfflineSeconds: base.runnerOfflineSeconds,
            runnerVersionSkewGraceSeconds: base.runnerVersionSkewGraceSeconds,
            queueDepthThreshold: base.queueDepthThreshold,
            oldestPendingSeconds: base.oldestPendingSeconds,
            errorRateThreshold: base.errorRateThreshold,
            errorRateWindowSize: base.errorRateWindowSize,
            errorRateMinimumSamples: base.errorRateMinimumSamples,
            editorUnrecoverableThreshold: base.editorUnrecoverableThreshold,
            editorUnrecoverableWindowMinutes: base.editorUnrecoverableWindowMinutes,
            brightspaceSyncFailureThreshold: base.brightspaceSyncFailureThreshold,
            brightspaceSyncFailureWindowMinutes: base.brightspaceSyncFailureWindowMinutes,
            outboundFailureThreshold: base.outboundFailureThreshold,
            outboundFailureWindowMinutes: base.outboundFailureWindowMinutes,
            webhookURLFromEnvironment: webhookURL
        )
    }

    /// A fresh path in the temporary directory, with nothing at it.
    private func webhookFilePath() -> String {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-alert-webhook-\(UUID().uuidString)").path
    }

    private func lowDisk(_ app: Application) {
        app.diskSpaceProbe = { _ in DiskSpace(freeBytes: 4 << 30, totalBytes: 93 << 30) }
    }

    private func healthyDisk(_ app: Application) {
        app.diskSpaceProbe = { _ in DiskSpace(freeBytes: 50 << 30, totalBytes: 100 << 30) }
    }

    private func diskRecords(_ monitor: ServerHealthAlertMonitor) async -> [AlertFiringRecord] {
        await monitor.recentFiringsSnapshot().filter { $0.rule == HealthRule.diskSpaceLow.rawValue }
    }

    // MARK: - Which webhook URL wins

    @Test func theFileOnDiskBeatsTheEnvironmentValue() async throws {
        let path = webhookFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)

        #expect(await monitor.effectiveWebhookURL() == "https://env.example/hook")

        try "  https://disk.example/hook\n".write(toFile: path, atomically: true, encoding: .utf8)
        #expect(await monitor.effectiveWebhookURL() == "https://disk.example/hook")
    }

    @Test func anAdminOverrideWinsAndIsSavedForTheNextProcess() async throws {
        let path = webhookFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        try "https://disk.example/hook".write(toFile: path, atomically: true, encoding: .utf8)
        let monitor = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)

        await monitor.setWebhookURL("  https://admin.example/hook  ")
        #expect(await monitor.effectiveWebhookURL() == "https://admin.example/hook")

        // A restarted server has no override in memory; it reads the saved file.
        let restarted = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)
        #expect(await restarted.effectiveWebhookURL() == "https://admin.example/hook")
    }

    @Test func clearingTheOverrideRemovesTheFileAndFallsBackToTheEnvironment() async {
        let path = webhookFilePath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        let monitor = ServerHealthAlertMonitor(
            configuration: configuration(webhookURL: "https://env.example/hook"), webhookURLFilePath: path)

        await monitor.setWebhookURL("https://admin.example/hook")
        #expect(FileManager.default.fileExists(atPath: path))

        await monitor.setWebhookURL("   ")
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(await monitor.effectiveWebhookURL() == "https://env.example/hook")
    }

    // MARK: - The test alert

    @Test func aRefusedTestAlertIsRecordedWithItsErrorAndRethrown() async throws {
        try await withTestApp { app in
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(
                configuration: configuration(webhookURL: refusedWebhookURL), webhookURLFilePath: path)

            await #expect(throws: WebhookNotifierError.self) {
                try await monitor.dispatchTestAlert(application: app)
            }

            let records = await monitor.recentFiringsSnapshot()
            let record = try #require(records.first)
            #expect(records.count == 1)
            #expect(record.rule == HealthRule.runnerOffline.rawValue)
            #expect(record.paged)
            #expect(!record.delivered)
            #expect(record.deliveryError == "Invalid webhook URL: \(refusedWebhookURL)")
            #expect(record.summary.contains("Test alert"))
        }
    }

    @Test func theRecentFiringsBufferKeepsOnlyTheNewestFifty() async throws {
        try await withTestApp { app in
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(configuration: configuration(), webhookURLFilePath: path)

            for _ in 0..<(ServerHealthAlertMonitor.recentFiringsCap + 3) {
                _ = try await monitor.dispatchTestAlert(application: app)
            }

            let records = await monitor.recentFiringsSnapshot()
            #expect(records.count == ServerHealthAlertMonitor.recentFiringsCap)
            let undelivered = records.count { !$0.delivered }
            #expect(undelivered == 0)
        }
    }

    // MARK: - A sweep

    @Test func aSweepRecordsAFiringRuleAndTheReasonItsPageFailed() async throws {
        try await withTestApp { app in
            lowDisk(app)
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(
                configuration: configuration(webhookURL: refusedWebhookURL), webhookURLFilePath: path)

            await monitor.sweep(application: app)

            let records = await diskRecords(monitor)
            let record = try #require(records.first)
            #expect(records.count == 1)
            #expect(!record.resolved)
            #expect(record.paged)
            #expect(!record.delivered)
            #expect(record.deliveryError == "Invalid webhook URL: \(refusedWebhookURL)")
            let states = await monitor.currentRuleStates()
            #expect(states[.diskSpaceLow]?.isFiring == true)
        }
    }

    @Test func aSweepPagesOnceWithinTheCooldownAndSaysWhenTheRuleResolves() async throws {
        try await withTestApp { app in
            lowDisk(app)
            let path = webhookFilePath()
            defer { try? FileManager.default.removeItem(atPath: path) }
            let monitor = ServerHealthAlertMonitor(
                configuration: configuration(cooldownSeconds: 600), webhookURLFilePath: path)
            let start = Date()

            await monitor.sweep(application: app, now: start)
            await monitor.sweep(application: app, now: start.addingTimeInterval(60))
            var records = await diskRecords(monitor)
            #expect(records.count == 1, "a second sweep inside the cooldown does not page again")
            #expect(records.first?.delivered == true)
            #expect(records.first?.deliveryError == nil)

            healthyDisk(app)
            await monitor.sweep(application: app, now: start.addingTimeInterval(120))
            records = await diskRecords(monitor)
            let resolved = try #require(records.first)
            #expect(records.count == 2)
            #expect(resolved.resolved)
            #expect(resolved.summary == "RESOLVED: \(HealthRule.diskSpaceLow.humanReadable)")
            let states = await monitor.currentRuleStates()
            #expect(states[.diskSpaceLow]?.isFiring == false)
        }
    }

    // MARK: - Boot

    @Test func bootStampsTheStartTimeEvenWhenAlertsAreOff() async throws {
        try await withTestApp { app in
            app.serverHealthAlertConfiguration = configuration(enabled: false)
            let stale = Date(timeIntervalSince1970: 0)
            app.serverStartedAt = stale

            try await ServerHealthAlertLifecycleHandler().didBootAsync(app)

            #expect(app.serverStartedAt > stale.addingTimeInterval(86400))
            await ServerHealthAlertLifecycleHandler().shutdownAsync(app)
        }
    }
}
