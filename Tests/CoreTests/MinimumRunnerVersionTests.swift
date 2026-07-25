// Tests/CoreTests/MinimumRunnerVersionTests.swift
//
// Pins the optional minimumRunnerVersion manifest gate: Codable back-compat (a
// manifest without the key decodes to nil), the round-trip, that a nil gate
// emits no key at all (byte-identity for un-gated manifests), and the
// runnerSanitized() strip (the gate is a server-side dispatch concern the
// runner never sees — enforcement runs at claim time before the Job is built).

import Foundation
import Testing

@testable import Core

@Suite struct MinimumRunnerVersionTests {

    @Test func manifestWithoutMinimumRunnerVersionDecodesNil() throws {
        let json = #"{"schemaVersion":1}"#
        let decoded = try JSONDecoder().decode(TestProperties.self, from: Data(json.utf8))
        #expect(decoded.minimumRunnerVersion == nil)
    }

    @Test func minimumRunnerVersionRoundTrips() throws {
        let manifest = TestProperties(minimumRunnerVersion: "0.5.0")
        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(TestProperties.self, from: data)
        #expect(decoded.minimumRunnerVersion == "0.5.0")
    }

    /// A nil gate must emit no `minimumRunnerVersion` key, so an un-gated
    /// manifest is byte-for-byte what it always was (encodeIfPresent).
    @Test func nilMinimumRunnerVersionEncodesNoKey() throws {
        let data = try JSONEncoder().encode(TestProperties())
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(!object.keys.contains("minimumRunnerVersion"))
    }

    @Test func runnerSanitizedStripsMinimumRunnerVersion() {
        let manifest = TestProperties(minimumRunnerVersion: "0.5.0")
        #expect(manifest.runnerSanitized().minimumRunnerVersion == nil)
    }

    @Test func nilByDefault() {
        #expect(TestProperties().minimumRunnerVersion == nil)
    }
}
