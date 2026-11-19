// Tests/CoreTests/DatasetDeliveryModeTests.swift
//
// `DatasetDeliveryMode` (docs/dataset-shared-delivery.md): a dataset is
// `shared`, linked once for every student, only when it gives every student
// the source bytes unchanged. A partition with no transform is `perPart`, each
// part stored once. A sample size or a transform makes it `perStudent`.

import Testing

@testable import Core

@Suite struct DatasetDeliveryModeTests {

    private static let blank = DatasetTransform(kind: .missingValues, columns: ["SBP"], rate: 0.1)

    @Test(
        "The mode follows the spec",
        arguments: [
            (DatasetSpec(file: "a.csv"), DatasetDeliveryMode.shared),
            (DatasetSpec(file: "a.csv", kind: .stratifiedSample, stratumColumn: "SEX"), .shared),
            (DatasetSpec(file: "a.csv", scope: .course), .shared),
            (DatasetSpec(file: "a.csv", sampleSize: 50), .perStudent),
            (DatasetSpec(file: "a.csv", kind: .stratifiedSample, sampleSize: 50, stratumColumn: "SEX"), .perStudent),
            (DatasetSpec(file: "a.csv", kind: .partition, partCount: 4), .perPart),
            (DatasetSpec(file: "a.csv", kind: .partition, transforms: [blank], partCount: 4), .perStudent),
            (DatasetSpec(file: "a.csv", kind: .partition), .perStudent),
            (DatasetSpec(file: "a.csv", transforms: [blank]), .perStudent),
        ])
    func modeFollowsSpec(spec: DatasetSpec, expected: DatasetDeliveryMode) {
        #expect(spec.deliveryMode == expected)
    }

    /// A sample at least as large as the file gives the whole file, but the rule
    /// reads only the spec, so it stays per student: the safe direction.
    @Test func sampleAtOrAboveRowCountIsStillPerStudent() {
        #expect(DatasetSpec(file: "a.csv", sampleSize: 1_000_000).deliveryMode == .perStudent)
    }

    /// The precondition `shared` rests on: with no sample and no transform, the
    /// materializer returns the source unchanged for any seed, so a link to the
    /// source is exactly what each student would otherwise be written.
    @Test(arguments: [DatasetKind.rowSample, .stratifiedSample])
    func sharedSpecMaterializesToTheSourceBytes(kind: DatasetKind) {
        let source = "id,SEX\r\n1,F\r\n2,M\r\n3,F"
        let spec = DatasetSpec(file: "a.csv", kind: kind, stratumColumn: kind == .stratifiedSample ? "SEX" : nil)
        #expect(spec.deliveryMode == .shared)
        for seed in ["00", "ab", "ffee"] {
            #expect(DatasetMaterializer.materialize(source: source, spec: spec, seedHex: seed) == source)
        }
    }
}
