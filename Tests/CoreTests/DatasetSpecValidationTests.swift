// Tests/CoreTests/DatasetSpecValidationTests.swift
//
// The save-time check every authoring door runs before storing a dataset spec
// (docs/datasets.md Phase 1.5).
//
// It exists because `DatasetMaterializer` deliberately does NOT fail on a
// stratified spec that does not fit its file — an unknown column degrades to a
// plain row sample, because at delivery time the only reader is a student being
// graded and an error helps them not at all. That forgiveness is only safe if
// the mistake is refused where it can still be fixed, so what these assert is
// the pairing: every case the materializer silently absorbs is a case this
// refuses.

import Foundation
import Testing

@testable import Core

@Suite struct DatasetSpecValidationTests {

    private let pool = """
        id,ward,score
        1,3A,7
        2,3B,4
        3,3A,9

        """

    private func stratified(size: Int?, column: String?) -> DatasetSpec {
        DatasetSpec(file: "cases.csv", kind: .stratifiedSample, sampleSize: size, stratumColumn: column)
    }

    @Test func aWellFormedStratifiedSpecPasses() {
        #expect(DatasetSpecValidation.issue(with: stratified(size: 2, column: "ward"), sourceCSV: pool) == nil)
    }

    @Test func aPlainRowSampleNeedsNoFileAtAll() {
        let spec = DatasetSpec(file: "cases.csv", sampleSize: 2)
        #expect(DatasetSpecValidation.issue(with: spec, sourceCSV: nil) == nil)
        #expect(DatasetSpecValidation.issue(with: spec, sourceCSV: pool) == nil)
    }

    @Test func aColumnOnAPlainRowSampleIsRefused() {
        // Stored, then ignored at delivery — the silent-mismatch shape the
        // whole check exists to prevent.
        let spec = DatasetSpec(file: "cases.csv", kind: .rowSample, sampleSize: 2, stratumColumn: "ward")
        let issue = DatasetSpecValidation.issue(with: spec, sourceCSV: pool)
        #expect(issue?.contains("only applies to a stratified sample") == true)
    }

    @Test func aStratifiedSpecWithoutAColumnIsRefused() {
        for column in [nil, "", "   "] {
            let issue = DatasetSpecValidation.issue(with: stratified(size: 2, column: column), sourceCSV: pool)
            #expect(issue != nil, "column \(String(describing: column))")
        }
    }

    @Test func anUnknownColumnIsRefusedAndTheRealOnesAreNamed() {
        let issue = DatasetSpecValidation.issue(with: stratified(size: 2, column: "unit"), sourceCSV: pool)
        // The instructor cannot see the file from the form they are typing in,
        // so the message has to carry what is actually there.
        #expect(issue?.contains("'unit'") == true)
        #expect(issue?.contains("'id'") == true)
        #expect(issue?.contains("'ward'") == true)
        #expect(issue?.contains("'score'") == true)
    }

    @Test func aSampleTooSmallForEveryCategoryIsRefused() {
        // `id` has three distinct values; two rows cannot hold them all, and
        // the apportionment would have to drop one.
        let issue = DatasetSpecValidation.issue(with: stratified(size: 2, column: "id"), sourceCSV: pool)
        #expect(issue?.contains("3 distinct values") == true)
        #expect(issue?.contains("at least 3") == true)

        #expect(
            DatasetSpecValidation.issue(with: stratified(size: 3, column: "id"), sourceCSV: pool) == nil,
            "a sample with room for every category passes")
    }

    @Test func aWholeFileSpecHasNoSizeToCheck() {
        // nil means "the whole file", which trivially contains every category.
        #expect(DatasetSpecValidation.issue(with: stratified(size: nil, column: "id"), sourceCSV: pool) == nil)
    }

    @Test func binaryOrEmptyFilesAreRefusedForStratification() {
        let binary = DatasetSpecValidation.issue(with: stratified(size: 2, column: "ward"), sourceCSV: nil)
        #expect(binary?.contains("not UTF-8 text") == true)
        let empty = DatasetSpecValidation.issue(with: stratified(size: 2, column: "ward"), sourceCSV: "")
        #expect(empty?.contains("empty") == true)
    }

    @Test func quotedHeadersResolveByTheirUnquotedName() {
        let quoted = """
            "id","ward, full name",score
            1,3A,7
            2,3B,4

            """
        #expect(
            DatasetSpecValidation.issue(
                with: stratified(size: 2, column: "ward, full name"), sourceCSV: quoted) == nil)
    }

    @Test func aLongHeaderIsTruncatedInTheMessage() {
        let wide = (0..<40).map { "c\($0)" }.joined(separator: ",") + "\n1\n"
        let issue = DatasetSpecValidation.issue(with: stratified(size: 2, column: "nope"), sourceCSV: wide)
        #expect(issue?.contains("…") == true, "a 40-column extract does not dump 40 names")
        #expect(issue?.contains("'c0'") == true)
    }

    // MARK: - Transforms

    private func withTransforms(
        _ transforms: [DatasetTransform], sampleSize: Int? = nil
    )
        -> DatasetSpec
    {
        DatasetSpec(file: "cases.csv", sampleSize: sampleSize, transforms: transforms)
    }

    private func blank(_ columns: [String], rate: Double?) -> DatasetTransform {
        DatasetTransform(kind: .missingValues, columns: columns, rate: rate)
    }

    @Test func aWellFormedTransformPasses() {
        #expect(
            DatasetSpecValidation.issue(
                with: withTransforms([blank(["score"], rate: 0.5)]), sourceCSV: pool) == nil)
    }

    @Test func aTransformNamingAnUnknownColumnIsRefusedWithTheRealColumns() {
        let issue = DatasetSpecValidation.issue(
            with: withTransforms([blank(["scoer"], rate: 0.5)]), sourceCSV: pool)
        #expect(issue?.contains("'scoer'") == true)
        // The instructor cannot see the file from the form they are typing into.
        #expect(issue?.contains("'score'") == true)
        #expect(issue?.contains("'ward'") == true)
    }

    @Test func aTransformNamingNoColumnIsRefused() {
        #expect(
            DatasetSpecValidation.issue(with: withTransforms([blank([], rate: 0.5)]), sourceCSV: pool)
                != nil)
    }

    @Test func aRateOutsideTheAllowedRangeIsRefused() {
        for rate in [nil, 0, -0.5, 1.5] as [Double?] {
            #expect(
                DatasetSpecValidation.issue(
                    with: withTransforms([blank(["score"], rate: rate)]), sourceCSV: pool) != nil,
                "rate \(String(describing: rate)) should be refused")
        }
        #expect(
            DatasetSpecValidation.issue(
                with: withTransforms([blank(["score"], rate: 1)]), sourceCSV: pool) == nil,
            "a rate of exactly 1 means every row, which is allowed")
    }

    /// The integer fold `(rows * permille) / 1000` is what delivery uses, so a
    /// rate below one row's worth of the student's sample does nothing at all.
    /// The instructor is the only person who can fix that.
    @Test func aRateTooSmallForTheSampleIsRefused() {
        let issue = DatasetSpecValidation.issue(
            with: withTransforms([blank(["score"], rate: 0.01)], sampleSize: 10), sourceCSV: pool)
        #expect(issue?.contains("affects no rows") == true)
        // The same rate over a big enough sample is fine.
        #expect(
            DatasetSpecValidation.issue(
                with: withTransforms([blank(["score"], rate: 0.01)], sampleSize: 100),
                sourceCSV: pool) == nil)
    }

    @Test func oneKindTwiceOnOneColumnIsRefused() {
        let issue = DatasetSpecValidation.issue(
            with: withTransforms([blank(["score"], rate: 0.2), blank(["score"], rate: 0.3)]),
            sourceCSV: pool)
        #expect(issue?.contains("more than once") == true)
    }

    @Test func theSameKindOnDifferentColumnsIsFine() {
        #expect(
            DatasetSpecValidation.issue(
                with: withTransforms([blank(["score"], rate: 0.2), blank(["ward"], rate: 0.3)]),
                sourceCSV: pool) == nil)
    }

    @Test func everySilentTransformDegradationHasALoudRefusal() {
        // Each of these leaves the data untouched at delivery — and each is
        // refused at save. Untouched data is the right answer for a student
        // being graded and the wrong answer for an instructor who thinks they
        // asked for something.
        let degrading: [DatasetSpec] = [
            withTransforms([blank(["nope"], rate: 0.5)]),
            withTransforms([blank([], rate: 0.5)]),
            withTransforms([blank(["score"], rate: nil)]),
            withTransforms([blank(["score"], rate: 0)]),
            withTransforms([blank(["score"], rate: 0.01)], sampleSize: 10),
        ]
        for spec in degrading {
            let delivered = DatasetMaterializer.materialize(
                source: pool, spec: spec, seedHex: String(repeating: "a1b2", count: 16))
            let inert = DatasetMaterializer.materialize(
                source: pool,
                spec: DatasetSpec(file: spec.file, sampleSize: spec.sampleSize),
                seedHex: String(repeating: "a1b2", count: 16))
            #expect(delivered == inert, "delivery absorbs: \(spec)")
            #expect(
                DatasetSpecValidation.issue(with: spec, sourceCSV: pool) != nil,
                "save refuses: \(spec)")
        }
    }

    // MARK: - The pairing with the materializer

    @Test func everySilentDegradationHasALoudRefusal() {
        // Each of these produces a plain row sample instead of a stratified one
        // at delivery — and each is refused at save.
        let degrading: [DatasetSpec] = [
            stratified(size: 2, column: nil),
            stratified(size: 2, column: ""),
            stratified(size: 2, column: "unit"),
        ]
        let plain = DatasetMaterializer.materialize(
            source: pool, spec: DatasetSpec(file: "cases.csv", sampleSize: 2),
            seedHex: String(repeating: "a1b2", count: 16))
        for spec in degrading {
            let delivered = DatasetMaterializer.materialize(
                source: pool, spec: spec, seedHex: String(repeating: "a1b2", count: 16))
            #expect(delivered == plain, "delivery degrades: \(spec)")
            #expect(DatasetSpecValidation.issue(with: spec, sourceCSV: pool) != nil, "save refuses: \(spec)")
        }
    }
}
