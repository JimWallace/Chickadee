// Tests/APITests/DiskSpaceRuleTests.swift
//
// The `diskSpaceLow` rule fires when less than 15% of the data disk is free, so
// that a filling disk pages before it stops Postgres (2026-10-07). It stays
// quiet when the disk cannot be measured. The storage page and the
// `get_storage_usage` tool carry the same measurement.

import Foundation
import Testing
import Vapor

@testable import APIServer

@Suite struct DiskSpaceRuleTests {

    private let gigabyte = 1024 * 1024 * 1024

    private func space(freeGB: Int, totalGB: Int) -> DiskSpace {
        DiskSpace(freeBytes: freeGB * gigabyte, totalBytes: totalGB * gigabyte)
    }

    @Test func anUnknownMeasurementDoesNotFire() {
        #expect(!decideDiskSpaceLow(nil).isFiring)
    }

    @Test func lessThanFifteenPercentFreeFiresWithTheNumbers() {
        let evaluation = decideDiskSpaceLow(space(freeGB: 9, totalGB: 93))
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.contains("free of"))
        #expect(evaluation.summary.contains("10%"))
        #expect(evaluation.details["free_percent"] == "10")
        #expect(evaluation.details["threshold_percent"] == "15")
        #expect(evaluation.details["free_bytes"] == String(9 * gigabyte))
    }

    @Test func fifteenPercentOrMoreFreeDoesNotFire() {
        #expect(!decideDiskSpaceLow(space(freeGB: 15, totalGB: 100)).isFiring)
        #expect(!decideDiskSpaceLow(space(freeGB: 65, totalGB: 93)).isFiring)
    }

    @Test func aFullDiskFires() {
        #expect(decideDiskSpaceLow(space(freeGB: 0, totalGB: 93)).isFiring)
    }

    @Test func theSummaryTextReadsAsFreeOfTotal() {
        #expect(space(freeGB: 25, totalGB: 100).summaryText == "25.0 GB free of 100.0 GB (25%)")
    }

    @Test func anExistingPathHasAMeasurableDisk() throws {
        let measured = try #require(DiskSpace.measure(atPath: FileManager.default.temporaryDirectory.path))
        #expect(measured.totalBytes > 0)
        #expect(measured.freeBytes >= 0)
        #expect(measured.freeBytes <= measured.totalBytes)
    }

    @Test func aMissingPathHasNoMeasurement() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-no-such-dir-\(UUID().uuidString)").path
        #expect(DiskSpace.measure(atPath: missing) == nil)
    }

    @Test func theRuleIsAWarningThatPages() {
        #expect(HealthRule.diskSpaceLow.severity == "warning")
        #expect(HealthRule.diskSpaceLow.pagesOperator)
    }

    @Test func theAlertsPageStatesTheThreshold() {
        let text = HealthRule.diskSpaceLow.thresholdText(.default)
        #expect(text.contains("15%"))
    }

    @Test func aDeployerHoldingForDiskSpaceFires() {
        let updated = ISO8601DateFormatter().string(from: Date())
        let status = DeployerStatus(
            state: "disk_low", detail: "only 4 GiB free; a deploy needs 10 GiB",
            deployedVersion: "0.5.551", latestSeen: "v0.5.552", paused: false, updatedAt: updated)
        let evaluation = decideDeployerUnhealthy(status: status, now: Date())
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.contains("disk_low"))
        #expect(evaluation.summary.contains("only 4 GiB free"))
    }

    // MARK: - Through a running app

    @Test func theRuleFiresInTheFullEvaluationWhenTheDataDiskIsLow() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            app.diskSpaceProbe = { _ in DiskSpace(freeBytes: 4 << 30, totalBytes: 93 << 30) }
            let results = await evaluateHealthRules(on: app, configuration: .default)
            let evaluation = try #require(results[.diskSpaceLow])
            #expect(evaluation.isFiring)
            #expect(evaluation.details["free_percent"] == "4")
        }
    }

    @Test func theStorageToolReportsTheDataDisk() async throws {
        let app = try await makeTestApp()
        try await withApp(app) { app in
            app.diskSpaceProbe = { _ in DiskSpace(freeBytes: 25 << 30, totalBytes: 100 << 30) }
            let context = try await AdminRoutes.makeStorageContext(
                req: Request(application: app, on: app.eventLoopGroup.any()))
            #expect(context.disk == DiskSpace(freeBytes: 25 << 30, totalBytes: 100 << 30))
            #expect(context.diskText == "25.0 GB of 100.0 GB (25%)")
        }
    }

    // MARK: - Storage context

    private func encoded(_ context: AdminStorageContext) throws -> [String: Any] {
        let data = try JSONEncoder().encode(context)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test func theStorageContextCarriesTheDisk() throws {
        var context = AdminStorageContext(rows: [], totalFormatted: "1.0 GB", dbBackend: "postgres", assignments: [])
        context.disk = space(freeGB: 25, totalGB: 100)
        let json = try encoded(context)
        let disk = try #require(json["disk"] as? [String: Any])
        #expect(disk["freeBytes"] as? Int == 25 * gigabyte)
        #expect(disk["totalBytes"] as? Int == 100 * gigabyte)
        #expect(json["diskText"] as? String == "25.0 GB of 100.0 GB (25%)")
        #expect(json["totalFormatted"] as? String == "1.0 GB")
    }

    @Test func aStorageContextWithoutADiskSaysSo() throws {
        let context = AdminStorageContext(rows: [], totalFormatted: "1.0 GB", dbBackend: "sqlite", assignments: [])
        let json = try encoded(context)
        #expect(json["disk"] == nil)
        #expect(json["diskText"] as? String == "unknown")
    }
}
