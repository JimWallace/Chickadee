// Tests/CoreTests/DatasetTransformTests.swift
//
// Pins derivation (docs/datasets.md): selection decides which rows a student
// gets, a transform decides what has been done to the values in them.
//
// The byte pins here matter more than usual. Nothing about a student's slice is
// stored — it is re-derived at every delivery, including a re-grade months later
// — so a change in these bytes is not a version bump. It is the student's data
// changing underneath them, and a re-grade scoring against rows they never had.
// Never re-baseline a failing pin to make an edit pass: a genuinely new
// behaviour is a new transform, not a changed one.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetTransformTests {

    private let seed = String(repeating: "a1b2", count: 16)

    /// Ten rows, three columns, values that make a blanked cell obvious.
    private let pool = """
        id,ward,systolic
        1,3A,120
        2,3B,131
        3,3A,118
        4,3C,142
        5,3B,127
        6,3A,135
        7,3C,111
        8,3B,150
        9,3A,124
        10,3C,139

        """

    private func blank(_ columns: [String], rate: Double) -> DatasetTransform {
        DatasetTransform(kind: .missingValues, columns: columns, rate: rate)
    }

    private func spec(_ transforms: [DatasetTransform], sampleSize: Int? = nil) -> DatasetSpec {
        DatasetSpec(file: "cases.csv", sampleSize: sampleSize, transforms: transforms)
    }

    private func materialize(_ spec: DatasetSpec, seedHex: String? = nil) -> String {
        DatasetMaterializer.materialize(source: pool, spec: spec, seedHex: seedHex ?? seed)
    }

    // MARK: - Byte pins

    @Test func missingValuesPinnedBytes() {
        // 30% of 10 rows = 3 cells blanked in `systolic`, rows in file order,
        // header and every other column untouched.
        #expect(
            materialize(spec([blank(["systolic"], rate: 0.3)]))
                == """
                id,ward,systolic
                1,3A,120
                2,3B,
                3,3A,
                4,3C,142
                5,3B,127
                6,3A,135
                7,3C,111
                8,3B,
                9,3A,124
                10,3C,139

                """)
    }

    @Test func twoColumnsPinnedBytes() {
        // 2 cells per column, each column drawing from its own sub-seeded
        // stream — `systolic`'s rows here are the first two of the three it
        // blanks at rate 0.3 above, which is the partial Fisher-Yates being
        // consistent rather than a coincidence.
        #expect(
            materialize(spec([blank(["ward", "systolic"], rate: 0.2)]))
                == """
                id,ward,systolic
                1,3A,120
                2,3B,
                3,3A,
                4,3C,142
                5,,127
                6,3A,135
                7,3C,111
                8,,150
                9,3A,124
                10,3C,139

                """)
    }

    // MARK: - Determinism

    @Test func sameInputsGiveSameBytes() {
        let s = spec([blank(["systolic"], rate: 0.4)])
        #expect(materialize(s) == materialize(s))
    }

    @Test func differentSeedsBlankDifferentRows() {
        let s = spec([blank(["systolic"], rate: 0.3)])
        #expect(
            materialize(s, seedHex: String(repeating: "1234", count: 16))
                != materialize(s, seedHex: String(repeating: "cdef", count: 16)))
    }

    /// The rule that keeps already-delivered data from moving: a transform's
    /// stream is sub-seeded on its own index, so appending a second step must
    /// not re-roll the first.
    @Test func appendingATransformLeavesTheFirstUntouched() {
        let first = blank(["systolic"], rate: 0.3)
        let alone = materialize(spec([first]))
        let withSecond = materialize(spec([first, blank(["ward"], rate: 0.2)]))

        // `systolic` must be blanked in exactly the same rows in both.
        #expect(systolicColumn(of: alone) == systolicColumn(of: withSecond))
        #expect(alone != withSecond, "the second transform must still have done something")
    }

    /// The same rule one level down: adding a column to a step must not move
    /// which rows an existing column blanks.
    @Test func addingAColumnLeavesTheOtherColumnUntouched() {
        let alone = materialize(spec([blank(["systolic"], rate: 0.3)]))
        let both = materialize(spec([blank(["systolic", "ward"], rate: 0.3)]))
        #expect(systolicColumn(of: alone) == systolicColumn(of: both))
    }

    @Test func orderIsLoadBearing() {
        // Two steps on one column in the other order are a different result, so
        // the array order has to be stored rather than normalized away.
        let a = materialize(spec([blank(["ward"], rate: 0.2), blank(["systolic"], rate: 0.5)]))
        let b = materialize(spec([blank(["systolic"], rate: 0.5), blank(["ward"], rate: 0.2)]))
        #expect(a != b)
    }

    // MARK: - The envelope selection already keeps

    @Test func headerAndRowOrderAndRowCountAreUnchanged() {
        let out = materialize(spec([blank(["systolic"], rate: 0.5)]))
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false)
        let poolLines = pool.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == poolLines.count)
        #expect(lines.first == poolLines.first, "the header is never touched")
        // Row identity is preserved — only the named column's cells change.
        #expect(
            lines.dropFirst().map { $0.split(separator: ",").first }
                == poolLines.dropFirst().map { $0.split(separator: ",").first })
    }

    @Test func trailingNewlineMirrorsTheInput() {
        let noTrailing = String(pool.dropLast())
        let out = DatasetMaterializer.materialize(
            source: noTrailing, spec: spec([blank(["systolic"], rate: 0.3)]), seedHex: seed)
        #expect(!out.hasSuffix("\n"))
        #expect(materialize(spec([blank(["systolic"], rate: 0.3)])).hasSuffix("\n"))
    }

    @Test func compositionWithSelectionAppliesToTheStudentsRows() {
        let out = materialize(spec([blank(["systolic"], rate: 0.5)], sampleSize: 4))
        let rows = out.split(separator: "\n").dropFirst()
        #expect(rows.count == 4, "selection runs first")
        // 50% of the 4 rows the student received, not of the 10-row pool.
        #expect(rows.filter { $0.hasSuffix(",") }.count == 2)
    }

    @Test func quotedFieldsAroundABlankedCellKeepTheirBytes() {
        let quoted = """
            id,note,systolic
            1,"Smith, J",120
            2,"Doe, A",131

            """
        let out = DatasetMaterializer.materialize(
            source: quoted,
            spec: DatasetSpec(file: "c.csv", transforms: [blank(["systolic"], rate: 1)]),
            seedHex: seed)
        // A rebuild would re-quote by this file's rules rather than the
        // source's; an in-place edit leaves every other cell byte-identical.
        #expect(
            out == """
                id,note,systolic
                1,"Smith, J",
                2,"Doe, A",

                """)
    }

    // MARK: - Degradation (each paired with a refusal in DatasetSpecValidationTests)

    @Test func unappliableTransformsLeaveTheDataAlone() {
        let unappliable: [DatasetTransform] = [
            blank(["nope"], rate: 0.5),  // no such column
            blank([], rate: 0.5),  // no columns named
            DatasetTransform(kind: .missingValues, columns: ["systolic"], rate: nil),  // no rate
            blank(["systolic"], rate: 0),  // a rate that affects nothing
            blank(["systolic"], rate: 0.01),  // too small to reach one row of ten
        ]
        for transform in unappliable {
            #expect(materialize(spec([transform])) == pool, "should be inert: \(transform)")
        }
    }

    // MARK: - Back-compat

    @Test func specWithoutTransformsKeyDecodesEmpty() throws {
        let json = #"{"file":"cases.csv","kind":"rowSample","sampleSize":10}"#
        let decoded = try JSONDecoder().decode(
            DatasetSpec.self, from: Data(json.utf8))
        #expect(decoded.transforms.isEmpty)
    }

    @Test func transformsRoundTrip() throws {
        let original = spec([blank(["systolic"], rate: 0.25)], sampleSize: 5)
        let decoded = try JSONDecoder().decode(
            DatasetSpec.self, from: JSONEncoder().encode(original))
        #expect(decoded == original)
    }

    /// A pre-derivation manifest must materialize to exactly what it did before
    /// derivation existed — the property that makes this change safe to ship to
    /// an assignment already in front of students.
    @Test func aSpecWithNoTransformsIsUnchangedBySelectionAlone() {
        let before = DatasetMaterializer.sampleRows(csv: pool, sampleSize: 4, seedHex: seed)
        let after = DatasetMaterializer.materialize(
            source: pool, spec: DatasetSpec(file: "cases.csv", sampleSize: 4), seedHex: seed)
        #expect(before == after)
    }

    /// The `systolic` column's cells, as delivered.
    private func systolicColumn(of csv: String) -> [String] {
        csv.split(separator: "\n").dropFirst().map { line in
            let fields = DatasetMaterializer.splitCSVLine(line)
            return fields.count > 2 ? fields[2] : ""
        }
    }
}
