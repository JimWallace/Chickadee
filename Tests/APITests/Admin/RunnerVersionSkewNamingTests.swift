import Foundation
import Testing

@testable import APIServer

/// The runner-version-skew alert names the runner that is behind. In Nov 2026
/// it paged "1 runner(s) behind server" every 30 minutes for four days without
/// saying that the runner was `Sparrow`.
@Suite struct RunnerVersionSkewNamingTests {

    @Test func summaryNamesTheRunnerAndCountsReleasesBehind() {
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.5.892",
            runners: [
                RunnerVersionReport(runnerID: "Hawk", version: "0.5.892"),
                RunnerVersionReport(runnerID: "Sparrow", version: "0.5.878"),
            ],
            serverUptimeSeconds: 100_000,
            graceSeconds: 1800
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.hasPrefix("Runner behind server v0.5.892: Sparrow at v0.5.878 (14 releases behind)"))
        #expect(!evaluation.summary.contains("Hawk"))
        #expect(evaluation.details["behind_runners"] == "Sparrow")
        #expect(evaluation.details["behind_count"] == "1")
        #expect(evaluation.details["oldest_runner_version"] == "0.5.878")
    }

    @Test func summaryNamesEveryRunnerBehind() {
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.5.892",
            runners: [
                RunnerVersionReport(runnerID: "Robin", version: "0.5.891"),
                RunnerVersionReport(runnerID: "Sparrow", version: "0.5.878"),
            ],
            serverUptimeSeconds: 100_000,
            graceSeconds: 1800
        )
        #expect(
            evaluation.summary.hasPrefix(
                "2 runners behind server v0.5.892: Robin at v0.5.891 (1 release behind), "
                    + "Sparrow at v0.5.878 (14 releases behind)"))
        #expect(evaluation.details["behind_runners"] == "Robin, Sparrow")
    }

    @Test func noReleaseCountAcrossAMinorBump() {
        // The patch number restarts at a minor bump, so 0.6.2 minus 0.5.878
        // is not a number of releases. The runner is still named.
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.6.2",
            runners: [RunnerVersionReport(runnerID: "Sparrow", version: "0.5.878")],
            serverUptimeSeconds: 100_000,
            graceSeconds: 1800
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.contains("Sparrow at v0.5.878 —"))
        #expect(!evaluation.summary.contains("releases behind"))
    }

    @Test func stillQuietWithinTheDeployGrace() {
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.5.892",
            runners: [RunnerVersionReport(runnerID: "Sparrow", version: "0.5.891")],
            serverUptimeSeconds: 600,
            graceSeconds: 1800
        )
        #expect(evaluation.isFiring == false)
    }

    @Test func storeReportsEachKnownRunnerWithItsID() async {
        let store = WorkerActivityStore()
        let now = Date()
        await store.markActive(workerID: "Sparrow", hostname: "h1", runnerVersion: "0.5.878", at: now)
        await store.markActive(workerID: "Hawk", hostname: "h2", runnerVersion: "0.5.892", at: now)
        // Seen two hours ago: beyond the remember window.
        await store.markActive(
            workerID: "Old", hostname: "h3", runnerVersion: "0.5.700", at: now.addingTimeInterval(-7200))
        // A keep-alive that never carried a version.
        await store.markActive(workerID: "Blank", hostname: "h4", at: now)

        let reports = await store.knownRunnerVersionsByID(rememberSeconds: 3600, now: now)
        #expect(
            reports == [
                RunnerVersionReport(runnerID: "Hawk", version: "0.5.892"),
                RunnerVersionReport(runnerID: "Sparrow", version: "0.5.878"),
            ])
    }
}
