// Tests/CoreTests/DatasetCapabilitiesTests.swift
//
// What a dataset's format lets a spec do, and a format this server does not
// know (docs/dataset-kinds-plan.md §5 and §6). Each format answers the
// selection questions once, in `DatasetFormat.capabilities`. A spec whose
// format is unknown still decodes, keeps its value, delivers the file whole
// and is refused at save; a bundle refuses an unknown format by name.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetCapabilitiesTests {

    @Test func eachFormatStatesItsCapabilities() {
        #expect(DatasetFormat.csv.capabilities == .table)
        #expect(DatasetFormat.csv.capabilities.selects)
        #expect(DatasetFormat.fhirNdjson.capabilities == .whole(unitName: "patient"))
        #expect(!DatasetFormat.fhirNdjson.capabilities.selects)
        #expect(!DatasetFormat.csv.entersThroughLibrary)
        #expect(DatasetFormat.fhirNdjson.entersThroughLibrary)
    }

    @Test(
        "A filename's candidate formats come from its extension",
        arguments: [
            ("cases.csv", [DatasetFormat.csv]), ("ED_FEED.NDJSON", [.fhirNdjson]), ("notes.txt", []), (".csv", []),
        ])
    func candidates(filename: String, expected: [DatasetFormat]) {
        #expect(DatasetFormat.candidates(forFilename: filename) == expected)
    }

    private static let futureSpec =
        #"{"file":"feed.jsonl","kind":"rowSample","sampleSize":2,"transforms":[],"#
        + #""format":"jsonRecords"}"#

    @Test func anUnknownFormatDecodesAndKeepsItsValue() throws {
        let spec = try JSONDecoder().decode(DatasetSpec.self, from: Data(Self.futureSpec.utf8))
        #expect(spec.unknownFormat == "jsonRecords")
        #expect(!spec.capabilities.selects)
        #expect(spec.deliveryMode == .shared)
        let encoded = try #require(String(data: ManifestCodec.stableEncoder.encode(spec), encoding: .utf8))
        #expect(encoded.contains(#""format":"jsonRecords""#))
        // A rebuild keeps it too.
        #expect(spec.withScope(.course).unknownFormat == "jsonRecords")
    }

    @Test func anUnknownFormatIsDeliveredWholeAndRefusedAtSave() throws {
        let spec = try JSONDecoder().decode(DatasetSpec.self, from: Data(Self.futureSpec.utf8))
        let source = "{\"a\":1}\n{\"a\":2}\n{\"a\":3}\n"
        #expect(
            DatasetMaterializer.materialize(source: source, spec: spec, seedHex: String(repeating: "a", count: 64))
                == source)
        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: source))
        #expect(issue.contains("'jsonRecords'"))
    }

    @Test func aKnownFormatHasNoUnknownValue() throws {
        let csv = try JSONDecoder().decode(DatasetSpec.self, from: Data(#"{"file":"a.csv","sampleSize":2}"#.utf8))
        #expect(csv.unknownFormat == nil)
        #expect(csv.format == .csv)
        let fhir = try JSONDecoder().decode(
            DatasetSpec.self, from: Data(#"{"file":"a.ndjson","format":"fhirNdjson"}"#.utf8))
        #expect(fhir.unknownFormat == nil)
        #expect(fhir.format == .fhirNdjson)
    }

    @Test func aBundleRefusesAnUnknownFormatByName() throws {
        let json =
            #"{"slug":"feed","name":"Feed","isPublished":false,"currentVersion":1,"versions":[],"#
            + #""format":"jsonRecords"}"#
        do {
            _ = try JSONDecoder().decode(BundledDataset.self, from: Data(json.utf8))
            Issue.record("An unknown format was accepted")
        } catch DecodingError.dataCorrupted(let context) {
            #expect(context.debugDescription.contains("'feed'"))
            #expect(context.debugDescription.contains("'jsonRecords'"))
        }
    }

    @Test func aSettingTheFormatLacksIsRefusedByTheCapabilityCheck() {
        let sampled = DatasetSpec(file: "a.ndjson", sampleSize: 3, format: .fhirNdjson)
        #expect(
            DatasetSpecValidation.capabilityIssue(with: sampled)
                == "'a.ndjson': a FHIR NDJSON dataset takes no sample size; every student receives the whole file.")
        #expect(DatasetSpecValidation.capabilityIssue(with: DatasetSpec(file: "a.csv", sampleSize: 3)) == nil)
    }
}
