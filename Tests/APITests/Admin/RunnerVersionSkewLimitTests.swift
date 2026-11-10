import Foundation
import Testing

@testable import APIServer

/// The runner-version-skew summary names at most `runnerVersionSkewNamedLimit`
/// runners, so a whole fleet behind cannot outgrow a webhook's message limit.
/// The release count reads the versions with `VersionComparator`, the parser
/// the comparison itself uses.
@Suite struct RunnerVersionSkewLimitTests {

    @Test func summaryNamesAtMostTheLimitAndCountsTheRest() {
        let runners = (1...8).map { RunnerVersionReport(runnerID: "R\($0)", version: "0.5.880") }
        let evaluation = decideRunnerVersionSkew(
            serverVersion: "0.5.892",
            runners: runners,
            serverUptimeSeconds: 100_000,
            graceSeconds: 1800
        )
        #expect(evaluation.isFiring)
        #expect(evaluation.summary.hasPrefix("8 runners behind server v0.5.892: R1 at v0.5.880"))
        #expect(evaluation.summary.contains("R5 at v0.5.880 (12 releases behind), and 3 more —"))
        #expect(!evaluation.summary.contains("R6"))
        // The details keep every name: they are not a one-line message.
        #expect(evaluation.details["behind_runners"] == "R1, R2, R3, R4, R5, R6, R7, R8")
    }

    @Test func releaseCountToleratesASuffixTheComparatorAccepts() {
        #expect(VersionComparator().releasesBehind("0.5.878-rc1", "0.5.892") == 14)
        #expect(VersionComparator().releasesBehind("0.5.892", "0.5.892") == nil)
        #expect(VersionComparator().releasesBehind("0.4.900", "0.5.2") == nil)
        #expect(VersionComparator().releasesBehind("dev", "0.5.2") == nil)
    }
}
