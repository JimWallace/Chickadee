// Tests/CoreTests/DatasetDescriptionVersionBoundaryTests.swift
//
// `DatasetDescription` reads every envelope version up to
// `currentVersion` and refuses a newer one. `DatasetDescriptionTests` checks
// version 2, but with an empty `fhirNdjson` payload, which fails to decode
// for its own reason, so the 2026-11-13 sweep (#3015) saw
// `version <= currentVersion` flipped to `>=` survive. That flip reads a
// future envelope as if this server understood it, and refuses an older one.
// Here each version carries a payload that decodes, so only the version
// check decides.

import Core
import Foundation
import Testing

@Suite struct DatasetDescriptionVersionBoundaryTests {

    private static let summary = FHIRDatasetSummary(
        fhirVersion: FHIRDatasetSummary.readAsVersion, resourceCount: 1, patientCount: 1,
        resourceTypes: [.init(resourceType: "Patient", count: 1)], codes: [],
        omittedCodeCount: 0, danglingPatientReferences: 0)

    /// The current envelope with its version replaced by `version`.
    private static func envelope(version: Int) throws -> Data {
        let data = try JSONEncoder().encode(DatasetDescription.fhirNdjson(summary))
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["descriptionVersion"] = version
        return try JSONSerialization.data(withJSONObject: object)
    }

    @Test(arguments: [0, DatasetDescription.currentVersion])
    func aVersionUpToTheCurrentOneIsRead(version: Int) throws {
        let read = try JSONDecoder().decode(DatasetDescription.self, from: Self.envelope(version: version))
        #expect(read == .fhirNdjson(Self.summary))
    }

    @Test(arguments: [DatasetDescription.currentVersion + 1, DatasetDescription.currentVersion + 7])
    func aNewerVersionIsRefused(version: Int) throws {
        let data = try Self.envelope(version: version)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(DatasetDescription.self, from: data)
        }
    }
}
