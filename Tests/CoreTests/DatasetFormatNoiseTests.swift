// Tests/CoreTests/DatasetFormatNoiseTests.swift
//
// Pins the `formatNoise` transform (docs/datasets.md, "formatNoise"): a
// chosen cell is written another way — padded with spaces, upper case or
// lower case — and never as another value, so trimming and case-folding a
// student's file gives the pool back.
//
// As in DatasetTransformTests, the byte pin is the student's data: a change
// in it is the data changing under a re-grade. Never re-baseline it to make
// an edit pass.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetFormatNoiseTests {

    private let seed = String(repeating: "a1b2", count: 16)

    private let pool = """
        id,ward,systolic
        1,Ward A,120
        2,Ward B,131
        3,Ward A,118
        4,Ward C,142
        5,Ward B,127
        6,Ward A,135
        7,Ward C,111
        8,Ward B,150
        9,Ward A,124
        10,Ward C,139

        """

    private func noise(_ columns: [String], rate: Double) -> DatasetTransform {
        DatasetTransform(kind: .formatNoise, columns: columns, rate: rate)
    }

    private func materialize(_ transforms: [DatasetTransform], source: String? = nil) -> String {
        DatasetMaterializer.materialize(
            source: source ?? pool, spec: DatasetSpec(file: "cases.csv", transforms: transforms), seedHex: seed)
    }

    /// Each data row's fields, trimmed and lower-cased.
    private func folded(_ csv: String) -> [[String]] {
        DatasetMaterializer.normalizedLines(of: csv).lines.dropFirst().map { line in
            DatasetMaterializer.splitCSVLine(line).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }
    }

    // MARK: - Byte pin

    @Test func formatNoisePinnedBytes() {
        // 40% of 10 rows = 4 cells of `ward` written another way; `id` and
        // `systolic` are untouched, and so are the other six wards.
        #expect(
            materialize([noise(["ward"], rate: 0.4)])
                == """
                id,ward,systolic
                1,ward a,120
                2,ward b,131
                3,Ward A,118
                4,Ward C,142
                5,Ward B,127
                6,Ward A,135
                7,Ward C,111
                8, Ward B ,150
                9,ward a,124
                10,Ward C,139

                """)
    }

    // MARK: - What it preserves

    /// Every cell, trimmed and case-folded, is the pool's cell: the step
    /// changes how a value is written, never the value.
    @Test func trimmingAndCaseFoldingGiveThePoolBack() {
        let noisy = materialize([noise(["ward", "systolic"], rate: 1)])
        #expect(noisy != pool)
        #expect(folded(noisy) == folded(pool))
    }

    /// At rate 1 every chosen cell changes: a case change that would change
    /// nothing, as on a number, adds the spaces instead.
    @Test func everyChosenCellChanges() {
        let noisy = folded(materialize([noise(["systolic"], rate: 1)]))
        let raw = DatasetMaterializer.normalizedLines(of: materialize([noise(["systolic"], rate: 1)])).lines
            .dropFirst().map { DatasetMaterializer.splitCSVLine($0)[2] }
        #expect(raw.allSatisfy { $0.hasPrefix(" ") && $0.hasSuffix(" ") })
        #expect(noisy.map { $0[2] } == folded(pool).map { $0[2] })
    }

    @Test func theRowsTheHeaderAndTheRowCountStay() {
        let noisy = materialize([noise(["ward"], rate: 0.5)])
        let lines = DatasetMaterializer.normalizedLines(of: noisy).lines
        #expect(lines.first == "id,ward,systolic")
        #expect(lines.count == 11)
        #expect(lines.dropFirst().map { DatasetMaterializer.splitCSVLine($0)[0] } == (1...10).map(String.init))
    }

    // MARK: - Cells it leaves alone

    @Test func anEmptyCellStaysEmpty() {
        let source = "id,ward\n1,\n2,\n3,\n"
        #expect(materialize([noise(["ward"], rate: 1)], source: source) == source)
    }

    /// A quoted cell keeps its quotes outside the change, so it stays one
    /// field with its comma.
    @Test func aQuotedCellStaysOneField() {
        let source = "id,ward\n1,\"Ward A, east\"\n"
        let noisy = materialize([noise(["ward"], rate: 1)], source: source)
        let fields = DatasetMaterializer.splitCSVLine(DatasetMaterializer.normalizedLines(of: noisy).lines[1])
        #expect(fields.count == 2)
        #expect(fields[1].trimmingCharacters(in: .whitespaces).lowercased() == "ward a, east")
        #expect(fields[1] != "Ward A, east")
    }

    @Test(arguments: [("Ward A", 0, " Ward A "), ("Ward A", 1, "WARD A"), ("Ward A", 2, "ward a"),
        ("120", 1, " 120 "), ("\"A, b\"", 2, "\"a, b\""), ("", 1, "")])
    func noisyWritesTheVariantItIsGiven(raw: String, variant: UInt64, written: String) {
        #expect(DatasetMaterializer.noisy(Substring(raw), variant: variant) == written)
    }

    // MARK: - Beside other steps

    /// Appending a noise step leaves the holes a blanking step made where they
    /// were, and a blank stays blank.
    @Test func appendingNoiseLeavesTheBlanksInPlace() {
        let blank = DatasetTransform(kind: .missingValues, columns: ["ward"], rate: 0.3)
        let blanked = materialize([blank])
        let both = materialize([blank, noise(["ward"], rate: 1)])
        let empties = { (csv: String) in
            DatasetMaterializer.normalizedLines(of: csv).lines.dropFirst().map {
                DatasetMaterializer.splitCSVLine($0)[1].isEmpty
            }
        }
        #expect(empties(both) == empties(blanked))
        #expect(folded(both) == folded(blanked))
    }

    // MARK: - Diagnostics

    /// The divergence measure compares folded text, so noise alone, on every
    /// row of an unsampled file, reads as no divergence at all.
    @Test func noiseAloneDoesNotDiverge() {
        let spec = DatasetSpec(file: "cases.csv", transforms: [noise(["ward"], rate: 1)])
        let ward = DatasetDiagnostics.divergence(spec: spec, sourceCSV: pool).first { $0.column == "ward" }
        #expect(ward?.worst == 0)
    }

    @Test func validationRefusesANoiseStepWithoutARate() {
        let spec = DatasetSpec(
            file: "cases.csv", transforms: [DatasetTransform(kind: .formatNoise, columns: ["ward"])])
        #expect(DatasetSpecValidation.transformIssue(with: spec, sourceCSV: pool)?.contains("needs a rate") == true)
    }
}
