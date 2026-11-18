// Tests/CoreTests/BundledDatasetFormatTests.swift
//
// A bundled dataset's format and the bundle version it sets
// (docs/fhir-datasets-plan.md §6). A CSV dataset encodes no format, so a
// bundle of CSV datasets keeps the bytes and the version 2 an older server
// reads. A FHIR dataset encodes its format and makes the bundle version 3,
// which a version 2 server refuses.

import Foundation
import Testing

@testable import Core

@Suite struct BundledDatasetFormatTests {

    private func dataset(_ format: DatasetFormat) -> BundledDataset {
        BundledDataset(
            slug: "ed-feed", name: "ED feed", description: nil, provenance: nil, licence: nil, isPublished: false,
            currentVersion: 1,
            versions: [
                BundledDatasetVersion(
                    version: 1, filename: "ed_feed.ndjson", sha256: String(repeating: "a", count: 64), sizeBytes: 10,
                    rowCount: 2, columns: [], note: nil)
            ], format: format)
    }

    private func encoded(_ dataset: BundledDataset) throws -> String {
        try #require(String(data: ManifestCodec.stableEncoder.encode(dataset), encoding: .utf8))
    }

    @Test func aCSVDatasetEncodesNoFormat() throws {
        #expect(try !encoded(dataset(.csv)).contains("format"))
    }

    @Test func aFHIRDatasetRoundTripsItsFormat() throws {
        let text = try encoded(dataset(.fhirNdjson))
        #expect(text.contains(#""format":"fhirNdjson""#))
        #expect(try JSONDecoder().decode(BundledDataset.self, from: Data(text.utf8)) == dataset(.fhirNdjson))
    }

    @Test func aVersionTwoDatasetDecodesAsCSV() throws {
        let text = try encoded(dataset(.csv))
        #expect(try JSONDecoder().decode(BundledDataset.self, from: Data(text.utf8)).format == .csv)
    }

    @Test(
        "The bundle version follows the formats it carries",
        arguments: [
            ([DatasetFormat](), 1), ([.csv], 2), ([.csv, .csv], 2), ([.fhirNdjson], 3), ([.csv, .fhirNdjson], 3),
        ])
    func schemaVersion(formats: [DatasetFormat], expected: Int) {
        #expect(CourseBundleManifest.schemaVersion(carrying: formats.map(dataset)) == expected)
    }

    @Test(
        "A non-CSV dataset needs version 3",
        arguments: [
            (1, [DatasetFormat.fhirNdjson], true), (2, [.csv, .fhirNdjson], true), (3, [.fhirNdjson], false),
            (2, [.csv], false), (1, [], false),
        ])
    func formatIssue(schemaVersion: Int, formats: [DatasetFormat], refused: Bool) {
        let issue = CourseBundleManifest.datasetFormatIssue(
            schemaVersion: schemaVersion, datasets: formats.map(dataset))
        #expect((issue != nil) == refused)
        if refused { #expect(issue?.contains("'ed-feed' is FHIR NDJSON") == true) }
    }

    @Test func anImportAcceptsVersionThree() {
        #expect(CourseBundleManifest.supportedSchemaVersions.contains(CourseBundleManifest.datasetFormatsSchemaVersion))
    }
}
