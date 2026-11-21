// Tests/CoreTests/Runner/WorkerExecutionReportCodableTests.swift
//
// `WorkerExecutionReport`: its JSON round-trip, and a legacy diagnostics
// payload without the disk fields.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct WorkerExecutionReportCodableTests: ISO8601CodingSuite {

    @Test func workerExecutionReportRoundTrip() throws {
        let col = TestOutcomeCollection(
            submissionID: "sub_r", testSetupID: "setup_r", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [],
            totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 0, runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let diag = WorkerExecutionDiagnostics(
            runnerID: "runner-01",
            startedAt: Date(timeIntervalSince1970: 1000),
            finishedAt: Date(timeIntervalSince1970: 1010),
            finalStatus: "passed",
            timedOut: false,
            exitCode: 0,
            terminationReason: nil,
            peakRSSBytes: 4096,
            wallClockMs: 10_000,
            childProcessCount: 2,
            stdoutBytes: 128,
            stderrBytes: 0,
            stageTimings: WorkerExecutionStageTimings(
                workdirSetupMs: 15,
                submissionDownloadMs: 120,
                testSetupAcquireMs: 45,
                submissionPrepareMs: 210,
                testExecutionMs: 10_000
            ),
            freeDiskMBAtStart: 1024,
            freeDiskMBAtEnd: 960,
            workdirPeakBytes: 33_554_432
        )
        let report = WorkerExecutionReport(collection: col, diagnostics: diag)

        let data = try encoder.encode(report)
        let decoded = try decoder.decode(WorkerExecutionReport.self, from: data)
        #expect(decoded.collection.submissionID == "sub_r")
        #expect(decoded.diagnostics?.runnerID == "runner-01")
        #expect(decoded.diagnostics?.timedOut == false)
        #expect(decoded.diagnostics?.peakRSSBytes == 4096)
        #expect(decoded.diagnostics?.terminationReason == nil)
        #expect(decoded.diagnostics?.stageTimings?.submissionDownloadMs == 120)
        #expect(decoded.diagnostics?.stageTimings?.testExecutionMs == 10_000)
        #expect(decoded.diagnostics?.freeDiskMBAtStart == 1024)
        #expect(decoded.diagnostics?.freeDiskMBAtEnd == 960)
        #expect(decoded.diagnostics?.workdirPeakBytes == 33_554_432)
    }

    @Test func workerExecutionDiagnosticsDecodesLegacyPayloadWithoutDiskFields() throws {
        // Older runners predate the disk-usage fields. Verify the synthesized
        // Codable decoder still accepts those payloads with the new optional
        // fields landing as nil.
        let legacyJSON = Data(
            """
            {
                "runnerID": "runner-legacy",
                "startedAt": "2024-01-01T00:00:00Z",
                "finishedAt": "2024-01-01T00:00:10Z",
                "finalStatus": "passed",
                "timedOut": false,
                "exitCode": 0,
                "terminationReason": null,
                "peakRSSBytes": null,
                "wallClockMs": 10000,
                "childProcessCount": null,
                "stdoutBytes": null,
                "stderrBytes": null,
                "stageTimings": null
            }
            """.utf8)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WorkerExecutionDiagnostics.self, from: legacyJSON)
        #expect(decoded.runnerID == "runner-legacy")
        #expect(decoded.freeDiskMBAtStart == nil)
        #expect(decoded.freeDiskMBAtEnd == nil)
        #expect(decoded.workdirPeakBytes == nil)
    }

    @Test func workerExecutionReportNilDiagnosticsRoundTrip() throws {
        let col = TestOutcomeCollection(
            submissionID: "sub_nd", testSetupID: "setup_nd", attemptNumber: 1,
            buildStatus: .passed, compilerOutput: nil, outcomes: [],
            totalTests: 0, passCount: 0, failCount: 0, errorCount: 0, timeoutCount: 0,
            executionTimeMs: 0, runnerVersion: "shell-runner/1.0",
            timestamp: Date(timeIntervalSince1970: 0)
        )
        let report = WorkerExecutionReport(collection: col, diagnostics: nil)
        let data = try encoder.encode(report)
        let decoded = try decoder.decode(WorkerExecutionReport.self, from: data)
        #expect(decoded.diagnostics == nil)
    }
}
