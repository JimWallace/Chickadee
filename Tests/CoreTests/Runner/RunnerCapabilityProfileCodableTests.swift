// Tests/CoreTests/Runner/RunnerCapabilityProfileCodableTests.swift
//
// `RunnerCapabilityProfile`: its JSON round-trip, full and empty.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct RunnerCapabilityProfileCodableTests: ISO8601CodingSuite {

    @Test func runnerCapabilityProfileRoundTrip() throws {
        let profile = RunnerCapabilityProfile(
            platform: "macos",
            architecture: "arm64",
            languageVersions: [
                LanguageVersion(language: "python", version: "3.12"),
                LanguageVersion(language: "r", version: "4.3.1"),
            ],
            capabilities: [RunnerCapability(name: "jupyter")]
        )
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(RunnerCapabilityProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.languageVersions.count == 2)
    }

    @Test func emptyRunnerCapabilityProfileRoundTrip() throws {
        let profile = RunnerCapabilityProfile(platform: "linux", architecture: "x86_64")
        let data = try encoder.encode(profile)
        let decoded = try decoder.decode(RunnerCapabilityProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.capabilities.isEmpty)
        #expect(decoded.languageVersions.isEmpty)
    }
}
