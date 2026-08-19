// Tests/CoreTests/DatasetDiagnosticsTests.swift
//
// The drift protection for the dataset diagnostics (DatasetDiagnostics.swift /
// DatasetDivergence.swift).  The load-bearing three:
//
//   * Completeness via `allCases` — a selection kind nobody wrote an overlap
//     formula for, or a transform kind nobody decided a row-set answer for,
//     fails here instead of quietly inheriting a plausible number.
//   * Analytic vs Monte Carlo — the compiler can check a formula exists,
//     never that it is right; simulated pairs check the value.
//   * Transforms do not change the row set — the theorem that licenses
//     overlap ignoring transforms entirely, which is what keeps this test
//     matrix linear instead of exponential.  If a row-dropping transform ever
//     ships, this fails, and the decomposition — not the test — needs
//     revisiting.
//
// The statistical tests use deterministic inputs (fixed seeds, fixed pools)
// with tolerance assertions, so they are exactly reproducible and cannot
// flake.  A failure means a wrong formula; re-derive it rather than widening
// the tolerance.

import Foundation
import Testing

@testable import Core

@Suite(.timeLimit(.minutes(2))) struct DatasetDiagnosticsTests {

    // MARK: - Fixture

    /// 200 unique rows: `id` 0–199, `ward` A×120 / B×60 / C×15 / D×5 (a
    /// deliberately rare stratum), `score` a spread of integers.
    private let pool: String = {
        var lines = ["id,ward,score"]
        for i in 0..<200 {
            let ward = i < 120 ? "A" : i < 180 ? "B" : i < 195 ? "C" : "D"
            lines.append("\(i),\(ward),\(50 + (i * 37) % 100)")
        }
        return lines.joined(separator: "\n") + "\n"
    }()

    private func plainSpec(_ size: Int?) -> DatasetSpec {
        DatasetSpec(file: "cases.csv", sampleSize: size)
    }

    private func stratifiedSpec(_ size: Int?, column: String = "ward") -> DatasetSpec {
        DatasetSpec(
            file: "cases.csv", kind: .stratifiedSample, sampleSize: size, stratumColumn: column)
    }

    private func dataRowIDs(spec: DatasetSpec, seedHex: String) -> [Substring] {
        let materialized = DatasetMaterializer.materialize(
            source: pool, spec: spec, seedHex: seedHex)
        let (lines, _) = DatasetMaterializer.normalizedLines(of: materialized)
        return lines.dropFirst().map { line in line.prefix(while: { $0 != "," }) }
    }

    private func simulatedMeanSharedRows(spec: DatasetSpec, pairs: Int) -> Double {
        var total = 0
        for pair in 0..<pairs {
            let a = Set(dataRowIDs(spec: spec, seedHex: "mc|\(pair)|a"))
            let b = Set(dataRowIDs(spec: spec, seedHex: "mc|\(pair)|b"))
            total += a.intersection(b).count
        }
        return Double(total) / Double(pairs)
    }

    // MARK: - 1. Completeness via allCases

    @Test(arguments: DatasetKind.allCases)
    func everySelectionKindAnswersTheOverlapFormula(kind: DatasetKind) throws {
        // Exhaustive switch: a new selection kind fails to compile here (and
        // in `DatasetDiagnostics.overlap`) until someone decides its formula.
        let spec: DatasetSpec
        switch kind {
        case .rowSample: spec = plainSpec(40)
        case .stratifiedSample: spec = stratifiedSpec(40)
        }
        let overlap = try #require(DatasetDiagnostics.overlap(spec: spec, sourceCSV: pool))
        #expect(overlap.poolRows == 200)
        #expect(overlap.rowsPerStudent == 40)
        #expect(overlap.expectedSharedRows > 0)
        #expect(overlap.sharedFraction > 0 && overlap.sharedFraction <= 1)
        #expect(overlap.worstPairSharedRows >= overlap.expectedSharedRows)
        #expect(overlap.worstPairSharedRows <= Double(overlap.rowsPerStudent))
    }

    @Test(arguments: DatasetTransform.Kind.allCases)
    func everyTransformKindHasADecidedRowSetAnswer(kind: DatasetTransform.Kind) {
        // Exhaustive switch: adding a transform kind forces a decision about
        // which columns a representative step touches — and the row-set test
        // below then holds it to "transforms never change which rows a
        // student holds".
        let transform: DatasetTransform
        switch kind {
        case .missingValues:
            transform = DatasetTransform(kind: .missingValues, columns: ["score"], rate: 0.5)
        }
        let with = DatasetSpec(file: "cases.csv", sampleSize: 40, transforms: [transform])
        for seed in 0..<5 {
            let seedHex = DatasetDiagnostics.preflightSeed(seed)
            #expect(
                dataRowIDs(spec: plainSpec(40), seedHex: seedHex)
                    == dataRowIDs(spec: with, seedHex: seedHex),
                "transform kind \(kind) changed the row set under seed \(seed)")
        }
    }

    // MARK: - 2. Analytic vs Monte Carlo

    @Test func plainOverlapMatchesSimulatedPairs() throws {
        let overlap = try #require(DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: pool))
        // Two 40-row samples of a 200-row pool: mean k²/N = 8 exactly.
        #expect(abs(overlap.expectedSharedRows - 8) < 1e-9)
        #expect(abs(overlap.sharedFraction - 0.2) < 1e-9)

        // 400 simulated pairs: σ ≈ 2.27 ⇒ standard error ≈ 0.11, so a 0.5
        // tolerance is ~4.4 standard errors — and the seeds are fixed, so
        // the observed mean is one number forever.
        let simulated = simulatedMeanSharedRows(spec: plainSpec(40), pairs: 400)
        #expect(abs(simulated - overlap.expectedSharedRows) < 0.5)
    }

    @Test func stratifiedOverlapMatchesSimulatedPairsAndHandComputedAllocation() throws {
        let overlap = try #require(
            DatasetDiagnostics.overlap(spec: stratifiedSpec(40), sourceCSV: pool))
        // Hamilton with a one-row floor over sizes [120, 60, 15, 5] at k = 40
        // allocates [23, 12, 3, 2], so Σ kₛ²/Nₛ = 23²/120 + 12²/60 + 9/15
        // + 4/5 = 985/120 — checkable by hand, independent of the code.
        #expect(abs(overlap.expectedSharedRows - 985.0 / 120.0) < 1e-9)

        let simulated = simulatedMeanSharedRows(spec: stratifiedSpec(40), pairs: 400)
        #expect(abs(simulated - overlap.expectedSharedRows) < 0.5)
    }

    // MARK: - 3. The rare-stratum consequence, by name

    @Test func theRareStratumIsReportedAsTheMostCopyable() throws {
        let overlap = try #require(
            DatasetDiagnostics.overlap(spec: stratifiedSpec(40), sourceCSV: pool))
        let stratum = try #require(overlap.mostCopyableStratum)
        // Every student takes 2 of ward D's 5 pool rows: a 40% pairwise
        // share on that stratum against 20% overall — stratification made
        // the rare category the most copyable part of the assignment.
        #expect(stratum.value == "D")
        #expect(stratum.poolRows == 5)
        #expect(stratum.rowsPerStudent == 2)
        #expect(abs(stratum.sharedFraction - 0.4) < 1e-9)
        #expect(
            DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: pool)?
                .mostCopyableStratum == nil,
            "a plain row sample has no strata to report")
    }

    // MARK: - 4. Theorems as tests

    @Test(arguments: [8, 20, 40, 100])
    func stratifiedOverlapIsNeverBelowPlainAtEqualSampleSize(size: Int) throws {
        // Titu's lemma: Σ kₛ²/Nₛ ≥ k²/N, equality only under exactly
        // proportional allocation — which the one-row floor prevents, so a
        // violation is definitely a bug, not a tolerance question.
        let plain = try #require(
            DatasetDiagnostics.overlap(spec: plainSpec(size), sourceCSV: pool))
        let stratified = try #require(
            DatasetDiagnostics.overlap(spec: stratifiedSpec(size), sourceCSV: pool))
        #expect(stratified.expectedSharedRows >= plain.expectedSharedRows - 1e-9)
    }

    @Test func moreRowsMeansMoreOverlapAndLessDivergence() throws {
        let small = try #require(DatasetDiagnostics.overlap(spec: plainSpec(20), sourceCSV: pool))
        let large = try #require(DatasetDiagnostics.overlap(spec: plainSpec(100), sourceCSV: pool))
        #expect(small.expectedSharedRows < large.expectedSharedRows)
        #expect(small.sharedFraction < large.sharedFraction)

        func scoreMedian(_ size: Int) throws -> Double {
            let divergences = DatasetDiagnostics.divergence(
                spec: plainSpec(size), sourceCSV: pool)
            return try #require(divergences.first { $0.column == "score" }).median
        }
        #expect(try scoreMedian(20) > scoreMedian(100))
    }

    // MARK: - 5. Overlap is selection-only

    @Test func overlapIgnoresTransformsBecauseTheyPreserveTheRowSet() {
        let blanked = DatasetSpec(
            file: "cases.csv", sampleSize: 40,
            transforms: [DatasetTransform(kind: .missingValues, columns: ["score"], rate: 0.5)])
        #expect(
            DatasetDiagnostics.overlap(spec: blanked, sourceCSV: pool)
                == DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: pool))
    }

    // MARK: - 6. Envelope cases mirror the materializer

    @Test func aWholeFileSpecMeansTotalOverlap() throws {
        for spec in [plainSpec(nil), plainSpec(0), plainSpec(200), plainSpec(5000)] {
            let overlap = try #require(DatasetDiagnostics.overlap(spec: spec, sourceCSV: pool))
            #expect(overlap.rowsPerStudent == 200)
            #expect(abs(overlap.sharedFraction - 1) < 1e-9)
            #expect(abs(overlap.expectedSharedRows - 200) < 1e-9)
            #expect(abs(overlap.worstPairSharedRows - 200) < 1e-9)
        }
    }

    @Test func aDegradedStratifiedSpecReportsWhatActuallyShips() {
        // An unknown column falls back to a plain row sample at delivery
        // (authoring refuses it, but the file can change under a saved spec)
        // — the estimate must describe those bytes, not the intended strata.
        let degraded = stratifiedSpec(40, column: "nope")
        #expect(
            DatasetDiagnostics.overlap(spec: degraded, sourceCSV: pool)
                == DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: pool))
    }

    @Test func aHeaderOnlyPoolHasNothingToEstimate() {
        #expect(DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: "id,ward\n") == nil)
        #expect(DatasetDiagnostics.divergence(spec: plainSpec(40), sourceCSV: "id,ward\n").isEmpty)
    }

    // MARK: - 7. The Wasserstein metric itself, by hand

    @Test func wassersteinIsPinnedOnHandComputableCases() {
        // Equal sizes: the mean absolute difference of order statistics.
        #expect(abs(DatasetDiagnostics.wasserstein1([0, 1, 2, 3], [0, 1, 2, 7]) - 1) < 1e-12)
        // Unequal sizes, by the quantile-function integral: [0,1] vs
        // [0,0,3] → segments 0·⅓ + 0·⅙ + 1·⅙ + 2·⅓ = ⅚.
        #expect(abs(DatasetDiagnostics.wasserstein1([0, 1], [0, 0, 3]) - 5.0 / 6.0) < 1e-12)
        // Identical distributions at different sample sizes transport nothing.
        #expect(DatasetDiagnostics.wasserstein1([1, 2], [1, 1, 2, 2]) == 0)
        // Two point masses transport their distance.
        #expect(abs(DatasetDiagnostics.wasserstein1([2.5], [4]) - 1.5) < 1e-12)
        // Order must not matter beyond sorting.
        #expect(
            DatasetDiagnostics.wasserstein1([3, 1, 2], [9, 4, 6])
                == DatasetDiagnostics.wasserstein1([1, 2, 3], [4, 6, 9]))
    }

    @Test func totalVariationIsPinnedOnHandComputableCases() {
        #expect(
            abs(
                DatasetDiagnostics.totalVariation(["a", "a", "b", "b"], ["a", "b", "b", "b"])
                    - 0.25) < 1e-12)
        #expect(DatasetDiagnostics.totalVariation(["a", "b"], ["b", "a"]) == 0)
        #expect(abs(DatasetDiagnostics.totalVariation(["a"], ["b"]) - 1) < 1e-12)
    }

    // MARK: - 8. Divergence

    @Test func divergenceClassifiesColumnsAndReportsInHeaderOrder() {
        let divergences = DatasetDiagnostics.divergence(spec: plainSpec(40), sourceCSV: pool)
        #expect(divergences.map(\.column) == ["id", "ward", "score"])
        #expect(divergences.map(\.measure) == [.wasserstein, .totalVariation, .wasserstein])
        for divergence in divergences {
            #expect(divergence.median >= 0)
            #expect(divergence.worst >= divergence.median)
        }
    }

    @Test func mcarBlankingDoesNotBiasTheObservedDistribution() throws {
        // `missingValues` thins a column without biasing it: the divergence
        // of the observed (non-blank) values must sit within sampling noise
        // of the unblanked spec's.  A future transform that *does* bias
        // fails here — the right moment to decide whether that is a bug or a
        // property it must declare.
        let blanked = DatasetSpec(
            file: "cases.csv", sampleSize: 100,
            transforms: [DatasetTransform(kind: .missingValues, columns: ["score"], rate: 0.3)])
        func scoreDivergence(_ spec: DatasetSpec) throws -> DatasetColumnDivergence {
            try #require(
                DatasetDiagnostics.divergence(spec: spec, sourceCSV: pool)
                    .first { $0.column == "score" })
        }
        let without = try scoreDivergence(plainSpec(100))
        let with = try scoreDivergence(blanked)
        #expect(abs(with.median - without.median) < 0.1)

        // And the thinning is real: 30% of the 100-row sample is blanked.
        let materialized = DatasetMaterializer.materialize(
            source: pool, spec: blanked, seedHex: DatasetDiagnostics.preflightSeed(0))
        let (lines, _) = DatasetMaterializer.normalizedLines(of: materialized)
        let observedScores = lines.dropFirst().count { line in
            !(DatasetMaterializer.splitCSVLine(line).last ?? "").isEmpty
        }
        #expect(observedScores == 70)
    }

    @Test func headlinesNameTheWorstColumnPerMeasureAndNeverAverage() {
        let divergences = [
            DatasetColumnDivergence(column: "id", measure: .wasserstein, median: 0.02, worst: 0.05),
            DatasetColumnDivergence(
                column: "systolic", measure: .wasserstein, median: 0.08, worst: 0.31),
            DatasetColumnDivergence(
                column: "ward", measure: .totalVariation, median: 0.11, worst: 0.19),
        ]
        let headlines = DatasetDiagnostics.headlines(of: divergences)
        #expect(headlines.count == 2)
        #expect(headlines.first?.measure == .wasserstein)
        #expect(headlines.first?.column == "systolic")
        #expect(abs((headlines.first?.worst ?? 0) - 0.31) < 1e-12)
        #expect(headlines.last?.measure == .totalVariation)
        #expect(headlines.last?.column == "ward")
        #expect(
            DatasetDiagnostics.headlines(of: Array(divergences.prefix(2))).count == 1,
            "a measure with no columns yields no headline")
    }

    // MARK: - 9. Deterministic seeds

    @Test func preflightSeedsAreDerivedAndPinned() {
        // Random preflight seeds would make the reported numbers flicker on
        // every page load, so an instructor could not tell whether their own
        // edit moved them.  The literal pin also catches an accidental
        // derivation change, which would silently re-map every multi-variant
        // consumer onto different variants.
        #expect(
            DatasetDiagnostics.preflightSeed(0)
                == "b0577888b859ff94b0577988b85a0147b0577a88b85a02fab0577b88b85a04ad")
        #expect(DatasetDiagnostics.preflightSeed(1).count == 64)
        #expect(DatasetDiagnostics.preflightSeed(0) != DatasetDiagnostics.preflightSeed(1))
    }

    @Test func twoRunsOverTheSameSpecAgreeExactly() {
        let spec = DatasetSpec(
            file: "cases.csv", kind: .stratifiedSample, sampleSize: 40, stratumColumn: "ward",
            transforms: [DatasetTransform(kind: .missingValues, columns: ["score"], rate: 0.2)])
        #expect(
            DatasetDiagnostics.divergence(spec: spec, sourceCSV: pool)
                == DatasetDiagnostics.divergence(spec: spec, sourceCSV: pool))
        #expect(
            DatasetDiagnostics.overlap(spec: spec, sourceCSV: pool)
                == DatasetDiagnostics.overlap(spec: spec, sourceCSV: pool))
    }

    // MARK: - 10. The worst-pair estimate

    /// The worst-pair number is the only one on `DatasetOverlap` an instructor
    /// acts on — "the unluckiest pair in your class is expected to share this
    /// many rows" — and until the 2026-08-19 sweep (run 32265903112) nothing
    /// asserted it was any different from the mean. The existing assertion is
    /// `worstPairSharedRows >= expectedSharedRows`, which equality satisfies,
    /// so five separate mutants collapsed the estimate onto the mean and
    /// survived: the variance guard's `poolRows > 1`, the pair count's
    /// `classSize > 1` (both as a relational flip and as a swapped ternary),
    /// and each half of `pairs >= 2, variance > 0`.
    ///
    /// Every one of them reports "the worst pair shares the average amount",
    /// which is the answer that makes a spec look safe.
    @Test func theWorstPairIsStrictlyWorseThanAverageForARealSample() throws {
        let overlap = try #require(DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: pool))
        #expect(
            overlap.worstPairSharedRows > overlap.expectedSharedRows,
            "an extreme-value estimate that equals the mean is not an estimate")
        #expect(overlap.worstPairSharedRows <= Double(overlap.rowsPerStudent))
    }

    /// The estimate's value, re-derived from the documented formula rather
    /// than copied from the implementation: `mean + sigma * sqrt(2 * ln pairs)`
    /// over a class's `C(C-1)/2` pairs, with the hypergeometric variance
    /// `k * (k/n) * (1 - k/n) * (n - k)/(n - 1)`.
    ///
    /// Pinning the number and not just the inequality is what separates "the
    /// spread is used at all" from "the spread is used correctly" — a mutant
    /// that drops the pair count to a constant, or halves the variance, still
    /// clears the inequality above.
    @Test func theWorstPairMatchesTheDocumentedClosedForm() throws {
        let n = 200.0
        let k = 40.0
        let mean = k * k / n
        let variance = k * (k / n) * (1 - k / n) * ((n - k) / (n - 1))
        let pairs =
            Double(DatasetDiagnostics.defaultClassSize)
            * Double(DatasetDiagnostics.defaultClassSize - 1) / 2
        let derived = mean + variance.squareRoot() * (2 * Foundation.log(pairs)).squareRoot()

        let overlap = try #require(DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: pool))
        #expect(abs(overlap.expectedSharedRows - mean) < 1e-9)
        #expect(abs(overlap.worstPairSharedRows - derived) < 1e-9)
    }

    /// The two degenerate inputs the guards exist for, stated as behaviour so
    /// they cannot be mistaken for the collapse above.
    ///
    /// A class of one has no pairs, and a whole-file sample has no variance —
    /// in both the honest answer IS the mean, and the estimate must not invent
    /// a spread. That is why the strict inequality above is asserted on a
    /// reducing sample at the default class size and nowhere else.
    @Test func theEstimateFallsBackToTheMeanWhenThereIsNothingToEstimate() throws {
        let soloClass = try #require(
            DatasetDiagnostics.overlap(spec: plainSpec(40), sourceCSV: pool, classSize: 1))
        #expect(soloClass.worstPairSharedRows == soloClass.expectedSharedRows)

        let wholeFile = try #require(DatasetDiagnostics.overlap(spec: plainSpec(nil), sourceCSV: pool))
        #expect(wholeFile.worstPairSharedRows == wholeFile.expectedSharedRows)
    }

    /// Stratification sums a variance per stratum, so the same collapse is
    /// reachable by a second route — and the rare-stratum floor means a
    /// stratified spec is exactly where an instructor most needs the worst
    /// pair to be honest.
    @Test func theStratifiedEstimateAlsoCarriesASpread() throws {
        let overlap = try #require(
            DatasetDiagnostics.overlap(spec: stratifiedSpec(40), sourceCSV: pool))
        #expect(overlap.worstPairSharedRows > overlap.expectedSharedRows)
        #expect(overlap.worstPairSharedRows <= Double(overlap.rowsPerStudent))
    }

}
