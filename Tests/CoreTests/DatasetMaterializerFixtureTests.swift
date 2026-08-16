// Tests/CoreTests/DatasetMaterializerFixtureTests.swift
//
// The byte-level pin on per-student dataset slicing.
//
// `DatasetMaterializerTests` asserts the PROPERTIES of a slice — deterministic
// within a run, header kept, order preserved. Those all hold for a materializer
// that quietly starts choosing different rows: two runs of the new code agree
// with each other perfectly. This file is the other half, and the one that
// matters when the materializer is edited: the exact bytes a known (source,
// spec, seed) produced before the edit.
//
// Why it is load-bearing. A student's slice is resolved from their seed at
// every delivery — the editor at notebook open, the worker at grade time, a
// re-grade months later. Nothing is stored. So a change in row selection is not
// a version bump, it is the student's data changing underneath them: the
// `describe()` numbers in their notebook stop matching what the grader sees,
// and a re-grade of an old submission scores against rows the student never
// had. The output must stay identical FOREVER, not merely self-consistent.
//
// If an edit fails one of these, the edit is wrong — do not re-baseline the
// literal. A genuinely new behaviour belongs behind a new `DatasetKind` case,
// which is exactly how stratified sampling was added beside `rowSample`.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetMaterializerFixtureTests {

    /// Two fixed 64-hex seeds, in the shape `PersonalizationSeed` produces.
    private let seedA = String(repeating: "a1b2", count: 16)
    private let seedB = String(repeating: "9f3c", count: 16)

    /// A 20-row two-column CSV — small enough to pin whole, wide enough that a
    /// row is identifiable in a failure diff.
    private let source20 = """
        id,ward
        0,3A
        1,3B
        2,3A
        3,4C
        4,3B
        5,3A
        6,4C
        7,3B
        8,3A
        9,4C
        10,3B
        11,3A
        12,4C
        13,3B
        14,3A
        15,4C
        16,3B
        17,3A
        18,4C
        19,3B

        """

    @Test func rowSampleFiveOfTwentySeedA() {
        let out = DatasetMaterializer.materialize(
            source: source20, spec: DatasetSpec(file: "cases.csv", sampleSize: 5), seedHex: seedA)
        #expect(
            out == """
                id,ward
                1,3B
                4,3B
                6,4C
                16,3B
                17,3A

                """)
    }

    @Test func rowSampleFiveOfTwentySeedB() {
        let out = DatasetMaterializer.materialize(
            source: source20, spec: DatasetSpec(file: "cases.csv", sampleSize: 5), seedHex: seedB)
        #expect(
            out == """
                id,ward
                1,3B
                3,4C
                10,3B
                11,3A
                15,4C

                """)
    }

    /// A sample big enough to walk the PRNG's rejection-sampling path many
    /// times, pinned by the chosen indices rather than the whole document.
    @Test func rowSampleThirtyOfTwoHundredSeedA() {
        var source = "id\n"
        source += (0..<200).map(String.init).joined(separator: "\n")
        source += "\n"
        let out = DatasetMaterializer.materialize(
            source: source, spec: DatasetSpec(file: "cases.csv", sampleSize: 30), seedHex: seedA)
        let rows = out.split(separator: "\n").dropFirst().compactMap { Int($0) }
        #expect(
            rows == [
                2, 6, 15, 27, 34, 35, 46, 60, 62, 85, 90, 93, 94, 97, 100,
                107, 113, 121, 122, 134, 143, 148, 149, 159, 165, 168, 175, 191, 193, 199,
            ])
    }
}
