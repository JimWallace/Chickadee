// Tests/CoreTests/DatasetDetachProjectionTests.swift
//
// `DatasetSpec.withoutLibraryFields` keeps a spec only when it still does
// something without the library: a sample or a transform. A spec with
// neither would be refused at the next `/datasets` edit
// (docs/datasets-course-library.md, slice 3).

import Testing

@testable import Core

@Suite struct DatasetDetachProjectionTests {

    @Test func aStratifiedSpecWithNoSampleHasNothingLeftToKeep() {
        let spec = DatasetSpec(
            file: "cases.csv", kind: .stratifiedSample, stratumColumn: "ward",
            source: DatasetSource(slug: "cases", version: 1))
        #expect(spec.withoutLibraryFields() == nil)
    }
}
