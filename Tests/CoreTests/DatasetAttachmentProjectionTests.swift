// Tests/CoreTests/DatasetAttachmentProjectionTests.swift
//
// The two Core helpers behind library attachments
// (docs/datasets-course-library.md, slice 3): the lookup that tells a
// support-file door a file is attached, and the projection that detach and
// the manifest doors use to drop the library fields without changing what a
// student receives.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetAttachmentProjectionTests {

    private let source = DatasetSource(slug: "vitaldb-cases", version: 2)

    @Test func theLookupFindsOnlyAnAttachedFile() {
        let props = TestProperties(
            language: nil,
            datasets: [
                DatasetSpec(file: "cases.csv", sampleSize: 3, source: source),
                DatasetSpec(file: "notes.csv", sampleSize: 2),
            ])
        #expect(props.libraryAttachment(for: "cases.csv")?.source == source)
        #expect(props.libraryAttachment(for: "notes.csv") == nil)
        #expect(props.libraryAttachment(for: "absent.csv") == nil)
    }

    @Test func dropTheLibraryFieldsKeepsTheSampleAndTheTransforms() {
        let spec = DatasetSpec(
            file: "cases.csv", kind: .stratifiedSample, sampleSize: 3, stratumColumn: "ward",
            transforms: [DatasetTransform(kind: .missingValues, columns: ["bp"], rate: 0.5)], source: source,
            scope: .course)
        #expect(
            spec.withoutLibraryFields()
                == DatasetSpec(
                    file: "cases.csv", kind: .stratifiedSample, sampleSize: 3, stratumColumn: "ward",
                    transforms: [DatasetTransform(kind: .missingValues, columns: ["bp"], rate: 0.5)]))
    }

    /// A whole-file attachment delivers the same bytes with no spec at all.
    @Test func aWholeFileAttachmentHasNothingLeftToKeep() {
        #expect(DatasetSpec(file: "cases.csv", source: source, scope: .course).withoutLibraryFields() == nil)
    }

    @Test func aWholeFileWithTransformsKeepsItsTransforms() {
        let spec = DatasetSpec(
            file: "cases.csv", transforms: [DatasetTransform(kind: .missingValues, columns: ["bp"], rate: 0.5)],
            source: source)
        #expect(spec.withoutLibraryFields()?.transforms.count == 1)
        #expect(spec.withoutLibraryFields()?.source == nil)
    }
}
