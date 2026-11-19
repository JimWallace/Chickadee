// Tests/CoreTests/DatasetAllPartsTests.swift
//
// `DatasetMaterializer.allParts` writes every part of a partition in one pass
// for the editor's part store (docs/dataset-shared-delivery.md). A student's
// linked part must be byte-for-byte what grading materializes for their deal,
// so each element is pinned to `materialize` for that part.

import Testing

@testable import Core

@Suite struct DatasetAllPartsTests {

    private static let sources = [
        "id,ward\n" + (1...10).map { "\($0),W\($0 % 3)" }.joined(separator: "\n") + "\n",
        "id,ward\r\n1,A\r\n2,B\r\n3,C",
        "id,ward\n1,A\n",
        "id,ward\n",
        "",
    ]

    @Test(arguments: sources, [1, 2, 3, 4, 7, 12])
    func eachPartMatchesTheMaterializer(source: String, partCount: Int) {
        let spec = DatasetSpec(file: "cases.csv", kind: .partition, partCount: partCount)
        let parts = DatasetMaterializer.allParts(csv: source, partCount: partCount)
        #expect(parts.count == partCount)
        for (part, bytes) in parts.enumerated() {
            for deal in [part, part + partCount] {
                #expect(
                    bytes
                        == DatasetMaterializer.materialize(source: source, spec: spec, seedHex: "ab", dealNumber: deal))
            }
        }
    }

    @Test func noPartCountGivesNoParts() {
        #expect(DatasetMaterializer.allParts(csv: "id\n1\n", partCount: 0).isEmpty)
    }
}
