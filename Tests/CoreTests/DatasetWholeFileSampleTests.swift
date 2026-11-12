// Tests/CoreTests/DatasetWholeFileSampleTests.swift
//
// `DatasetWholeFileSample` decides when a sample covers its whole file and
// what a save stores in its place (docs/dataset-shared-delivery.md,
// "Whole-file samples").

import Core
import Testing

@Suite struct DatasetWholeFileSampleTests {

    private static let source = DatasetSource(slug: "cases", version: 1)

    @Test func countsDataRowsAsTheMaterializerDoes() {
        #expect(DatasetWholeFileSample.dataRowCount(of: "id\n1\n2\n3\n") == 3)
        #expect(DatasetWholeFileSample.dataRowCount(of: "id\r\n1\r\n2") == 2)
        #expect(DatasetWholeFileSample.dataRowCount(of: "id\n") == 0)
        #expect(DatasetWholeFileSample.dataRowCount(of: "") == 0)
    }

    /// A sample at or above the count delivers the source unchanged, which is
    /// what makes it safe to store no sample instead.
    @Test(arguments: [3, 4, 384])
    func aSampleAtOrAboveTheCountDeliversTheSource(sampleSize: Int) {
        let csv = "id,ward\n1,A\n2,B\n3,A\n"
        let spec = DatasetSpec(file: "cases.csv", sampleSize: sampleSize)
        #expect(DatasetWholeFileSample.deliversWholeFile(spec, dataRowCount: 3))
        #expect(DatasetMaterializer.materialize(source: csv, spec: spec, seedHex: "ab12") == csv)
    }

    @Test func aRealSampleATransformAndAPartitionAreNotWholeFile() {
        let transformed = DatasetSpec(
            file: "cases.csv", sampleSize: 9,
            transforms: [DatasetTransform(kind: .missingValues, columns: ["ward"], rate: 0.5)])
        #expect(!DatasetWholeFileSample.deliversWholeFile(DatasetSpec(file: "c.csv", sampleSize: 2), dataRowCount: 3))
        #expect(!DatasetWholeFileSample.deliversWholeFile(transformed, dataRowCount: 3))
        #expect(
            !DatasetWholeFileSample.deliversWholeFile(
                DatasetSpec(file: "c.csv", kind: .partition, partCount: 2), dataRowCount: 3))
        #expect(!DatasetWholeFileSample.deliversWholeFile(DatasetSpec(file: "c.csv"), dataRowCount: 3))
    }

    @Test func aLibrarySpecIsKeptWithNoSampleAndAPlainOneIsLeftAlone() {
        let library = DatasetSpec(
            file: "cases.csv", kind: .stratifiedSample, sampleSize: 3, stratumColumn: "ward", source: Self.source,
            scope: .course)
        let expected = DatasetSpec(file: "cases.csv", source: Self.source, scope: .course)
        #expect(DatasetWholeFileSample.normalization(of: library, dataRowCount: 3) == .shared(expected))
        #expect(expected.deliveryMode == .shared)

        let plain = DatasetSpec(file: "notes.csv", sampleSize: 3)
        #expect(DatasetWholeFileSample.normalization(of: plain, dataRowCount: 3) == .unchanged)
        #expect(
            DatasetWholeFileSample.normalization(of: DatasetSpec(file: "n.csv", sampleSize: 2), dataRowCount: 3)
                == .unchanged)
    }
}
