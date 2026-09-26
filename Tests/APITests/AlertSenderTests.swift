// Tests/APITests/AlertSenderTests.swift
//
// In Sept 2026 production paged "Runners not polling: Sparrow for 9h 29m" every
// 30 minutes while the live server saw Sparrow poll every 30 seconds. The page
// could not say which process had sent it, and its relative quiet time could not
// be compared with the database. These tests pin the three things added so the
// next page can: the sender's identity, the absolute last-seen time, and a
// failed snapshot read that stays green instead of crashing the sweep.

import Core
import Foundation
import SQLKit
import Testing
import VaporTesting

@testable import APIServer

@Suite(.timeLimit(.minutes(2))) struct AlertSenderTests {

    private let startedAt = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - Sender identity

    @Test func itNamesTheHostVersionAndBootTime() {
        let sender = AlertSender(host: "3e877ba359c5", version: "0.5.242", startedAt: startedAt)
        #expect(
            sender.details == [
                "server_host": "3e877ba359c5",
                "server_version": "0.5.242",
                "server_started_at": "2027-01-15T08:00:00Z",
            ])
    }

    @Test func theSlackLineSaysWhichProcessSentIt() {
        let sender = AlertSender(host: "3e877ba359c5", version: "0.5.242", startedAt: startedAt)
        #expect(
            sender.text(summary: "Runners not polling: Sparrow for 9h 29m")
                == "[Chickadee] Runners not polling: Sparrow for 9h 29m (from 3e877ba359c5, v0.5.242)")
    }

    @Test func theCurrentSenderIsThisProcess() {
        let sender = AlertSender.current(startedAt: startedAt)
        #expect(sender.host == ProcessInfo.processInfo.hostName)
        #expect(sender.version == ChickadeeVersion.current)
        #expect(sender.startedAt == startedAt)
    }

    // MARK: - Absolute last-seen times

    @Test func theRuleReportsEachQuietRunnersLastSeenTime() {
        let evaluation = decideRunnersMissing(
            lastSeenByRunner: [
                "Starling": startedAt.addingTimeInterval(-7200),
                "Sparrow": startedAt.addingTimeInterval(-3600),
                "Chickadee": startedAt.addingTimeInterval(-5),
            ],
            offlineSeconds: 300,
            now: startedAt
        )
        #expect(evaluation.details["last_seen"] == "Sparrow 2027-01-15T07:00:00Z, Starling 2027-01-15T06:00:00Z")
    }

    // MARK: - A failed read

    @Test func aFailedSnapshotReadStaysGreen() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            let sql = try #require(app.db as? any SQLDatabase)
            try await sql.raw("DROP TABLE runner_snapshots").run()

            let results = await evaluateHealthRules(on: app, configuration: .default, now: startedAt)

            let evaluation = try #require(results[.runnerMissing])
            #expect(!evaluation.isFiring)
        }
    }
}
