// Tests/APITests/Assignments/DatasetFormatUploadCheckTests.swift
//
// `datasetFormatRefusal` (docs/fhir-datasets-plan.md §6): the zip upload brings
// a whole manifest, so it runs the format's save-time checks on each spec. A
// FHIR spec must name a `.ndjson` file whose lines are FHIR resources, and a CSV
// spec may not sit on a `.ndjson` file. A CSV spec on any other name is not
// read at all.
//
// `.serialized`: these spawn zip subprocesses, which race under within-suite
// parallelism (see `AssignmentVersionCaptureTests`).

import ChickadeeTestSupport
import Core
import Foundation
import Testing

@testable import APIServer

@Suite(.serialized, .timeLimit(.minutes(2))) struct DatasetFormatUploadCheckTests {

    private static let feed =
        #"{"resourceType":"Patient","id":"p1"}"# + "\n"
        + #"{"resourceType":"Observation","id":"o1","subject":{"reference":"Patient/p1"}}"# + "\n"

    private func withZip(
        _ entries: [(String, String)], _ body: (String) async throws -> Void
    ) async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("chickadee-format-upload-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let zip = dir.appendingPathComponent("setup.zip").path
        try await writeZipFixture(at: zip, entries: entries)
        try await body(zip)
    }

    /// The library source itself is checked by `CourseDatasetService.sourceIssue`,
    /// which the upload runs first.
    @Test func aWellFormedFHIRFileFromTheLibraryIsAccepted() async throws {
        try await withZip([("ed_feed.ndjson", Self.feed)]) { zip in
            let spec = DatasetSpec(
                file: "ed_feed.ndjson", source: DatasetSource(slug: "ed-feed", version: 1), format: .fhirNdjson)
            #expect(await datasetFormatRefusal(spec, zipPath: zip) == nil)
        }
    }

    @Test func aFHIRSpecWithNoLibrarySourceIsRefused() async throws {
        try await withZip([("ed_feed.ndjson", Self.feed)]) { zip in
            let spec = DatasetSpec(file: "ed_feed.ndjson", format: .fhirNdjson)
            let refusal = try #require(await datasetFormatRefusal(spec, zipPath: zip))
            #expect(refusal.contains("course library"))
        }
    }

    @Test func aMissingFileIsNamedAsMissing() async throws {
        try await withZip([("other.txt", "x")]) { zip in
            let spec = DatasetSpec(file: "ed_feed.ndjson", format: .fhirNdjson)
            let refusal = try #require(await datasetFormatRefusal(spec, zipPath: zip))
            #expect(refusal.contains("not among this assignment's bundled files"))
        }
    }

    @Test func aBrokenFHIRFileIsRefused() async throws {
        try await withZip([("ed_feed.ndjson", Self.feed + "{not json}\n")]) { zip in
            let spec = DatasetSpec(file: "ed_feed.ndjson", format: .fhirNdjson)
            let refusal = try #require(await datasetFormatRefusal(spec, zipPath: zip))
            #expect(refusal.contains("line 3 is not a JSON object"))
        }
    }

    @Test func aSampleOnAFHIRSpecIsRefused() async throws {
        try await withZip([("ed_feed.ndjson", Self.feed)]) { zip in
            let spec = DatasetSpec(file: "ed_feed.ndjson", sampleSize: 1, format: .fhirNdjson)
            let refusal = try #require(await datasetFormatRefusal(spec, zipPath: zip))
            #expect(refusal.contains("no sample size"))
        }
    }

    @Test func aCSVSpecOnAnNDJSONFileIsRefused() async throws {
        try await withZip([("ed_feed.ndjson", Self.feed)]) { zip in
            let spec = DatasetSpec(file: "ed_feed.ndjson", sampleSize: 1)
            #expect(await datasetFormatRefusal(spec, zipPath: zip) != nil)
        }
    }

    @Test func aCSVSpecOnAnyOtherNameIsNotChecked() async throws {
        try await withZip([("rows.txt", "not,a,real\ncsv")]) { zip in
            #expect(await datasetFormatRefusal(DatasetSpec(file: "rows.txt", sampleSize: 1), zipPath: zip) == nil)
        }
    }
}
