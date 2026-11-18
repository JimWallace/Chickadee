// Tests/CoreTests/FHIRDatasetSpecTests.swift
//
// `DatasetSpec.format` and the first release's rule for a FHIR NDJSON dataset
// (docs/fhir-datasets-plan.md §6 and §11): every student receives the whole
// file, byte for byte. The format encodes only when it is not CSV, every
// rebuild carries it, delivery ignores a selecting setting on it, and
// authoring refuses one.

import Foundation
import Testing

@testable import Core

@Suite struct FHIRDatasetSpecTests {

    static let feed = FHIRNdjsonProfileTests.feed
    static let source = DatasetSource(slug: "ed-feed", version: 1)

    private func encoded(_ spec: DatasetSpec) throws -> String {
        try #require(String(data: ManifestCodec.stableEncoder.encode(spec), encoding: .utf8))
    }

    // MARK: - Encoding

    @Test func aCSVSpecWritesNoFormat() throws {
        #expect(try !encoded(DatasetSpec(file: "cases.csv", sampleSize: 5)).contains("format"))
    }

    @Test func aSpecWithNoFormatDecodesAsCSV() throws {
        let json = #"{"file":"cases.csv","kind":"rowSample","transforms":[]}"#
        #expect(try JSONDecoder().decode(DatasetSpec.self, from: Data(json.utf8)).format == .csv)
    }

    @Test func aFHIRSpecRoundTrips() throws {
        let spec = DatasetSpec(file: "ed_feed.ndjson", source: Self.source, format: .fhirNdjson)
        let text = try encoded(spec)
        #expect(
            text
                == #"{"file":"ed_feed.ndjson","format":"fhirNdjson","kind":"rowSample","#
                + #""source":{"slug":"ed-feed","version":1},"transforms":[]}"#)
        #expect(try JSONDecoder().decode(DatasetSpec.self, from: Data(text.utf8)) == spec)
    }

    /// Every rebuild of a spec carries the format, as it carries the library
    /// fields (docs/feature-interactions.md).
    @Test func rebuildsCarryTheFormat() {
        let spec = DatasetSpec(
            file: "ed_feed.ndjson", sampleSize: 5, source: Self.source, format: .fhirNdjson)
        #expect(spec.withScope(.course).format == .fhirNdjson)
    }

    /// A detached FHIR file needs no spec: it is delivered whole either way,
    /// so the detach drops the spec rather than keep a FHIR spec with no
    /// library behind it.
    @Test func aDetachedFHIRFileKeepsNoSpec() {
        let spec = DatasetSpec(file: "ed_feed.ndjson", source: Self.source, format: .fhirNdjson)
        #expect(spec.withoutLibraryFields() == nil)
    }

    // MARK: - Delivery

    @Test(
        "A FHIR file is delivered whole for any seed and deal",
        arguments: [
            DatasetSpec(file: "ed_feed.ndjson", format: .fhirNdjson),
            DatasetSpec(file: "ed_feed.ndjson", sampleSize: 1, format: .fhirNdjson),
            DatasetSpec(file: "ed_feed.ndjson", kind: .partition, partCount: 2, format: .fhirNdjson),
            DatasetSpec(
                file: "ed_feed.ndjson",
                transforms: [DatasetTransform(kind: .missingValues, columns: ["id"], rate: 1)],
                format: .fhirNdjson),
        ])
    func deliveredWhole(spec: DatasetSpec) {
        for seed in ["00", "ab" + String(repeating: "7", count: 62)] {
            for deal in [nil, 0, 1, 5] {
                #expect(
                    DatasetMaterializer.materialize(source: Self.feed, spec: spec, seedHex: seed, dealNumber: deal)
                        == Self.feed)
            }
        }
        #expect(spec.deliveryMode == .shared)
        #expect(spec.isShared)
        #expect(spec.part(forDeal: 1) == nil)
    }

    @Test func aFHIRPartitionNeedsNoDealNumber() {
        let props = TestProperties(
            language: nil,
            datasets: [DatasetSpec(file: "ed_feed.ndjson", kind: .partition, partCount: 2, format: .fhirNdjson)])
        #expect(!props.hasPartitionedDatasets)
    }

    // MARK: - Save-time checks

    @Test func aWholeFHIRFileIsAccepted() {
        let spec = DatasetSpec(file: "ed_feed.ndjson", source: Self.source, format: .fhirNdjson)
        #expect(DatasetSpecValidation.issue(with: spec, sourceCSV: Self.feed) == nil)
    }

    @Test(
        "A FHIR spec refuses every setting that selects or changes rows",
        arguments: [
            (DatasetSpec(file: "ed_feed.ndjson", sampleSize: 5, format: .fhirNdjson), "no sample size"),
            (
                DatasetSpec(file: "ed_feed.ndjson", kind: .partition, partCount: 2, format: .fhirNdjson),
                "cannot be split"
            ),
            (
                DatasetSpec(
                    file: "ed_feed.ndjson", kind: .stratifiedSample, stratumColumn: "gender", format: .fhirNdjson),
                "no stratum"
            ),
            (
                DatasetSpec(
                    file: "ed_feed.ndjson",
                    transforms: [DatasetTransform(kind: .formatNoise, columns: ["gender"], rate: 0.5)],
                    format: .fhirNdjson),
                "no transforms"
            ),
            (DatasetSpec(file: "ed_feed.json", format: .fhirNdjson), "'.ndjson'"),
        ])
    func refusals(spec: DatasetSpec, phrase: String) throws {
        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: Self.feed))
        #expect(issue.contains(phrase))
    }

    @Test func aBrokenFileIsRefusedWithItsLine() throws {
        let spec = DatasetSpec(file: "ed_feed.ndjson", format: .fhirNdjson)
        let text = #"{"resourceType":"Patient","id":"p1"}"# + "\n" + #"{"resourceType":"Patient"}"#
        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: text))
        #expect(issue == "'ed_feed.ndjson': line 2 is a Patient with no id. Each resource needs an id.")
    }

    /// A FHIR dataset enters through the course library, the one door that
    /// sets the format.
    @Test func aFHIRSpecNeedsALibrarySource() throws {
        let spec = DatasetSpec(file: "ed_feed.ndjson", format: .fhirNdjson)
        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: Self.feed))
        #expect(issue.contains("attached from the course library"))
    }

    @Test func bytesThatAreNotTextAreRefused() throws {
        let spec = DatasetSpec(file: "ed_feed.ndjson", format: .fhirNdjson)
        let issue = try #require(DatasetSpecValidation.issue(with: spec, sourceCSV: nil))
        #expect(issue.contains("not UTF-8"))
    }

    /// A CSV spec may sit on any file name but a FHIR one: a hand-marked
    /// dataset has never needed a `.csv` name.
    @Test func aCSVSpecRefusesOnlyAnNDJSONName() throws {
        let ndjson = DatasetSpec(file: "ed_feed.NDJSON", sampleSize: 1)
        #expect(try #require(DatasetSpecValidation.issue(with: ndjson, sourceCSV: "a\n1\n")).contains("FHIR NDJSON"))
        #expect(
            DatasetSpecValidation.issue(with: DatasetSpec(file: "rows.txt", sampleSize: 1), sourceCSV: "a\n1\n") == nil)
    }

    /// Only the library attach path sets the format.
    @Test func otherDoorsCannotChangeTheFormat() {
        let stored = DatasetSpec(file: "ed_feed.ndjson", source: Self.source, format: .fhirNdjson)
        let dropped = DatasetSpec(file: "ed_feed.ndjson", source: Self.source)
        #expect(DatasetSpecValidation.libraryFieldIssue(proposed: dropped, stored: stored) != nil)
        #expect(DatasetSpecValidation.libraryFieldIssue(proposed: stored, stored: stored) == nil)
        let claimed = DatasetSpec(file: "ed_feed.ndjson", sampleSize: 1, format: .fhirNdjson)
        #expect(DatasetSpecValidation.libraryFieldIssue(proposed: claimed, stored: nil) != nil)
    }

    // MARK: - Format

    @Test(
        "A format matches its own extension only",
        arguments: [
            (DatasetFormat.csv, "a.csv", true), (.csv, "A.CSV", true), (.csv, ".csv", false),
            (.csv, "a.ndjson", false), (.fhirNdjson, "feed.ndjson", true), (.fhirNdjson, "feed.json", false),
        ])
    func extensions(format: DatasetFormat, filename: String, matches: Bool) {
        #expect(format.matches(filename: filename) == matches)
    }
}
