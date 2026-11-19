// Tests/APITests/Diagnostics/AssetLoadStatsTests.swift
//
// AssetLoadStats reads the `asset_load` message format that
// Public/kernel-asset-telemetry.js writes. These pin the parse (an unknown or
// malformed field reads as absent, never as a failure) and the fold.

import Foundation
import Testing

@testable import APIServer

@Suite struct AssetLoadStatsTests {
    @Test func aMessageParsesIntoItsFields() {
        let sample = AssetLoadStats.Sample(
            message: "cold=1;net_bytes=1200;cache_bytes=300;net_n=4;cache_n=1;shell_net_bytes=50;"
                + "shell_cache_bytes=7;boot_ms=8100;env=chickadee-python")
        #expect(sample.cold == true)
        #expect(sample.networkBytes == 1200)
        #expect(sample.cachedBytes == 300)
        #expect(sample.shellNetworkBytes == 50)
        #expect(sample.shellCachedBytes == 7)
        #expect(sample.bootMs == 8100)
    }

    @Test func absentMalformedAndNegativeFieldsReadAsAbsent() {
        let sample = AssetLoadStats.Sample(message: "probe=unsupported;net_bytes=lots;cache_bytes=-5;junk")
        #expect(sample.cold == nil)
        #expect(sample.networkBytes == 0)
        #expect(sample.cachedBytes == 0)
        #expect(sample.bootMs == nil)
        #expect(AssetLoadStats.Sample(message: nil).cold == nil)
    }

    @Test func aWarmDurationStandsInForTheBootDuration() {
        #expect(AssetLoadStats.Sample(message: "cold=0;warm_ms=4000").bootMs == 4000)
    }

    @Test func theFoldCountsColdLoadsOverKnownLoadsOnly() {
        let stats = AssetLoadStats.fold(
            key: "editor",
            samples: [
                .init(cold: true, networkBytes: 10, cachedBytes: 0, bootMs: 300),
                .init(cold: false, networkBytes: 0, cachedBytes: 20, bootMs: 100),
                .init(cold: false, networkBytes: 0, cachedBytes: 20, bootMs: 200),
                .init(cold: nil, bootMs: nil),
            ])
        #expect(stats.loads == 4)
        #expect(stats.coldLoads == 1)
        #expect(stats.unknownLoads == 1)
        #expect(stats.coldShare == 0.333)
        #expect(stats.networkBytes == 10)
        #expect(stats.cachedBytes == 40)
        #expect(stats.bootMsMedian == 200)
        #expect(stats.bootMsP90 == 300)
    }

    @Test func aGroupWithNoKnownLoadHasNoShare() {
        let stats = AssetLoadStats.fold(key: "editor", samples: [.init(cold: nil)])
        #expect(stats.coldShare == nil)
        #expect(stats.bootMsMedian == nil)
    }

    @Test func thePercentileIsNearestRank() {
        #expect(AssetLoadStats.percentile([], 0.5) == nil)
        #expect(AssetLoadStats.percentile([7], 0.9) == 7)
        #expect(AssetLoadStats.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 0.9) == 9)
        #expect(AssetLoadStats.percentile([1, 2, 3, 4], 0.5) == 2)
    }

    @Test func groupsComeBackBySourceAndByDay() {
        let bySource = AssetLoadStats.bySource([
            (source: "prewarm", message: "cold=1"),
            (source: "editor", message: "cold=1"),
            (source: "editor", message: "cold=0"),
            (source: nil, message: "cold=0"),
        ])
        #expect(bySource.map(\.key) == ["editor", "prewarm", "unknown"])
        let byDay = AssetLoadStats.byDay([
            (day: "2026-11-10/editor", message: "cold=0"),
            (day: "2026-11-09/editor", message: "cold=1"),
        ])
        #expect(byDay.map(\.key) == ["2026-11-09/editor", "2026-11-10/editor"])
    }
}
