// Tests/CoreTests/Runner/WorkerActivityPayloadCodableTests.swift
//
// `WorkerActivityPayload`, the runner's heartbeat: its JSON round-trip with
// and without a capability profile.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct WorkerActivityPayloadCodableTests: ISO8601CodingSuite {

    @Test func workerActivityPayloadRoundTrip() throws {
        let profile = RunnerCapabilityProfile(
            platform: "linux",
            architecture: "arm64",
            languageVersions: [LanguageVersion(language: "python", version: "3.11")],
            capabilities: [RunnerCapability(name: "jupyter")]
        )
        let payload = WorkerActivityPayload(
            workerID: "runner-01",
            hostname: "host.example.com",
            runnerVersion: "0.4.36",
            maxConcurrentJobs: 4,
            activeJobs: 2,
            profile: profile
        )

        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(WorkerActivityPayload.self, from: data)
        #expect(decoded.workerID == "runner-01")
        #expect(decoded.maxConcurrentJobs == 4)
        #expect(decoded.activeJobs == 2)
        #expect(decoded.profile?.platform == "linux")
        #expect(decoded.profile?.languageVersions.first?.language == "python")
    }

    @Test func workerActivityPayloadNilProfileRoundTrip() throws {
        let payload = WorkerActivityPayload(
            workerID: "runner-02", hostname: "h", runnerVersion: "0.4.0",
            maxConcurrentJobs: 1, activeJobs: 0, profile: nil
        )
        let data = try encoder.encode(payload)
        let decoded = try decoder.decode(WorkerActivityPayload.self, from: data)
        #expect(decoded.profile == nil)
    }
}
