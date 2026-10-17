// Tests/CoreTests/DatasetLibraryFieldsTests.swift
//
// The course-library fields on `DatasetSpec` (docs/datasets-course-library.md,
// slice 1): `source` and `scope` decode with defaults, a spec without them
// encodes to exactly the bytes it did before they existed, and the save-time
// checks refuse a course scope without a source and any change to the library
// fields through a door that is not the library attach path.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetLibraryFieldsTests {

    private func encoded(_ spec: DatasetSpec) throws -> String {
        try #require(String(data: ManifestCodec.stableEncoder.encode(spec), encoding: .utf8))
    }

    private let librarySource = DatasetSource(slug: "vitaldb-cases", version: 2)

    @Test func aSpecWrittenBeforeTheLibraryDecodesToTheDefaults() throws {
        let json = #"{"file":"cases.csv","kind":"rowSample","sampleSize":5}"#
        let spec = try JSONDecoder().decode(DatasetSpec.self, from: Data(json.utf8))
        #expect(spec.source == nil)
        #expect(spec.scope == .assignment)
    }

    /// The manifest hash gates the retest fan-out and the runner cache, so a
    /// stored manifest must re-encode to the same bytes.
    @Test func aSpecWithDefaultLibraryFieldsEncodesAsItDidBefore() throws {
        let stratified = DatasetSpec(
            file: "cases.csv", kind: .stratifiedSample, sampleSize: 5, stratumColumn: "ward",
            transforms: [DatasetTransform(kind: .missingValues, columns: ["bp"], rate: 0.1)])
        #expect(
            try encoded(stratified)
                == #"{"file":"cases.csv","kind":"stratifiedSample","sampleSize":5,"stratumColumn":"ward","#
                + #""transforms":[{"columns":["bp"],"kind":"missingValues","rate":0.1}]}"#)
        #expect(
            try encoded(DatasetSpec(file: "cases.csv"))
                == #"{"file":"cases.csv","kind":"rowSample","transforms":[]}"#)
    }

    @Test func libraryFieldsRoundTrip() throws {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5, source: librarySource, scope: .course)
        let text = try encoded(spec)
        #expect(text.contains(#""scope":"course""#))
        #expect(text.contains(#""source":{"slug":"vitaldb-cases","version":2}"#))
        let decoded = try JSONDecoder().decode(DatasetSpec.self, from: Data(text.utf8))
        #expect(decoded == spec)
    }

    @Test func anAssignmentScopeIsNotWritten() throws {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5, source: librarySource, scope: .assignment)
        #expect(try !encoded(spec).contains("scope"))
    }

    // MARK: - Save-time checks

    @Test func aCourseScopeWithoutASourceIsRefused() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5, scope: .course)
        #expect(DatasetSpecValidation.scopeIssue(with: spec) != nil)
        #expect(DatasetSpecValidation.issue(with: spec, sourceCSV: "id\n1\n2\n") != nil)
    }

    @Test func aCourseScopeWithASourcePassesTheScopeCheck() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5, source: librarySource, scope: .course)
        #expect(DatasetSpecValidation.scopeIssue(with: spec) == nil)
    }

    /// The silent half of the pair: a course scope with no source slices with
    /// the assignment seed, never the pool.
    @Test func theRefusedScopeDegradesToTheAssignmentSeed() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 5, scope: .course)
        let assignmentSeed = String(repeating: "a1b2", count: 16)
        #expect(
            DatasetSeedDerivation.effectiveSeed(
                spec: spec, assignmentSeedHex: assignmentSeed,
                courseSeedHex: String(repeating: "c3d4", count: 16)) == assignmentSeed)
    }

    @Test func aDoorThatCarriesTheStoredLibraryFieldsPasses() {
        let stored = DatasetSpec(file: "cases.csv", sampleSize: 5, source: librarySource, scope: .course)
        let edited = DatasetSpec(file: "cases.csv", sampleSize: 9, source: librarySource, scope: .course)
        #expect(DatasetSpecValidation.libraryFieldIssue(proposed: edited, stored: stored) == nil)
        #expect(
            DatasetSpecValidation.libraryFieldIssue(
                proposed: DatasetSpec(file: "cases.csv", sampleSize: 9), stored: nil) == nil)
    }

    @Test(arguments: [
        DatasetSpec(file: "cases.csv", sampleSize: 5, source: DatasetSource(slug: "vitaldb-cases", version: 2)),
        DatasetSpec(file: "cases.csv", sampleSize: 5, source: DatasetSource(slug: "other", version: 1)),
        DatasetSpec(
            file: "cases.csv", sampleSize: 5, source: DatasetSource(slug: "vitaldb-cases", version: 3), scope: .course),
    ])
    func aDoorThatSetsOrChangesALibraryFieldIsRefused(proposed: DatasetSpec) {
        let stored = DatasetSpec(file: "cases.csv", sampleSize: 5)
        #expect(DatasetSpecValidation.libraryFieldIssue(proposed: proposed, stored: stored) != nil)
    }

    @Test func aDoorThatDropsTheStoredSourceIsRefused() {
        let stored = DatasetSpec(file: "cases.csv", sampleSize: 5, source: librarySource, scope: .course)
        let dropped = DatasetSpec(file: "cases.csv", sampleSize: 5)
        #expect(DatasetSpecValidation.libraryFieldIssue(proposed: dropped, stored: stored) != nil)
    }
}
