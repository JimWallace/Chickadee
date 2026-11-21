// Tests/CoreTests/Grading/BuildStatusCodableTests.swift
//
// `BuildStatus`: its raw values and its JSON round-trip.
// Split by subject out of the former `CoreCodableTests`.

import Foundation
import Testing

@testable import Core

@Suite struct BuildStatusCodableTests: ISO8601CodingSuite {

    @Test(
        arguments: zip(
            [BuildStatus.passed, .failed, .skipped],
            ["passed", "failed", "skipped"]
        ))
    func buildStatusRawValue(status: BuildStatus, raw: String) {
        #expect(status.rawValue == raw)
    }

    @Test(arguments: [BuildStatus.passed, .failed, .skipped])
    func buildStatusRoundTrip(status: BuildStatus) throws {
        let data = try encoder.encode(status)
        let decoded = try decoder.decode(BuildStatus.self, from: data)
        #expect(decoded == status)
    }
}
