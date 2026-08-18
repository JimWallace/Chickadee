// Tests/APITests/DatasetEstimateSummaryTests.swift
//
// The wording and number formatting of the Files panel's two estimate chips
// (DatasetEditHelpers.datasetEstimateSummary).  The underlying statistics
// have their own suite in CoreTests (DatasetDiagnosticsTests); what is
// pinned here is the display layer the page JS paints verbatim — one
// concise number per chip, a phrase naming what it measures in the title —
// so a wording regression is caught in Swift rather than in a browser.

import Foundation
import Testing

@testable import APIServer
@testable import Core

@Suite struct DatasetEstimateSummaryTests {

    /// 200 unique rows: `id` 0–199, `ward` A×120 / B×60 / C×15 / D×5 (a
    /// deliberately rare stratum), `score` a spread of integers — the same
    /// shape as the CoreTests fixture.
    private let pool: String = {
        var lines = ["id,ward,score"]
        for i in 0..<200 {
            let ward = i < 120 ? "A" : i < 180 ? "B" : i < 195 ? "C" : "D"
            lines.append("\(i),\(ward),\(50 + (i * 37) % 100)")
        }
        return lines.joined(separator: "\n") + "\n"
    }()

    @Test func aPlainSampleGetsBothChipsWithTheDetailInTheTitles() throws {
        let summary = try #require(
            datasetEstimateSummary(
                for: DatasetSpec(file: "cases.csv", sampleSize: 40),
                sourceCSV: pool, divergenceMeasurable: true))

        // 40 of 200 rows: k/N = 20%, expected shared k²/N = 8.
        #expect(summary.similarityDisplay == "similarity 20%")
        #expect(summary.similarityTitle.contains("of 40"))
        #expect(summary.similarityTitle.contains("Unluckiest pair of 100"))
        #expect(
            !summary.similarityTitle.contains("Most shared"),
            "a plain sample has no strata to name")

        // One number; the worst column, its measure and the unlucky-variant
        // value ride the title.
        #expect(summary.driftDisplay.wholeMatch(of: /drift (\d+\.\d{2}|<0\.01)/) != nil)
        #expect(summary.driftTitle.contains("Worst column \""))
        #expect(summary.driftTitle.contains("on an unlucky variant"))
    }

    /// The chips' titles are assembled from measured numbers in Swift, so
    /// `scripts/check-ui-vocabulary.sh` — which reads templates — cannot see
    /// them.  This holds the same budget on the path the script cannot reach,
    /// across every branch that produces a title.
    @Test(arguments: [true, false]) func everyTitleStaysWithinTheHoverBudget(
        measurable: Bool
    ) throws {
        for spec in [
            DatasetSpec(file: "cases.csv", sampleSize: 40),
            DatasetSpec(file: "cases.csv", sampleSize: nil),
            DatasetSpec(
                file: "cases.csv", kind: .stratifiedSample, sampleSize: 40,
                stratumColumn: "ward"),
        ] {
            let summary = try #require(
                datasetEstimateSummary(
                    for: spec, sourceCSV: pool, divergenceMeasurable: measurable))
            for (label, title) in [
                ("similarity", summary.similarityTitle), ("drift", summary.driftTitle),
            ] {
                let words = title.split(whereSeparator: \.isWhitespace).count
                #expect(
                    words <= datasetEstimateTitleWordCap,
                    """
                    the \(label) title is \(words) words, over the \
                    \(datasetEstimateTitleWordCap)-word hover budget — a tooltip holds a \
                    phrase, and the explanation belongs in docs/datasets.md: \(title)
                    """)
            }
        }
    }

    @Test func aStratifiedSampleNamesItsMostSharedCategory() throws {
        let summary = try #require(
            datasetEstimateSummary(
                for: DatasetSpec(
                    file: "cases.csv", kind: .stratifiedSample, sampleSize: 40,
                    stratumColumn: "ward"),
                sourceCSV: pool, divergenceMeasurable: true))
        // The one-row floor makes rare ward D the most copyable part: every
        // student draws 2 of its 5 pool rows.
        #expect(summary.similarityTitle.contains("Most shared: \"D\" (40%)"))
    }

    @Test func aWholeFileSpecIsTotalSimilarity() throws {
        let summary = try #require(
            datasetEstimateSummary(
                for: DatasetSpec(file: "cases.csv", sampleSize: nil),
                sourceCSV: pool, divergenceMeasurable: true))
        #expect(summary.similarityDisplay == "similarity 100%")
    }

    @Test func anUnmeasurableFileSaysSoInsteadOfShowingNothing() throws {
        let summary = try #require(
            datasetEstimateSummary(
                for: DatasetSpec(file: "cases.csv", sampleSize: 40),
                sourceCSV: pool, divergenceMeasurable: false))
        #expect(summary.driftDisplay == "drift —")
        #expect(summary.driftTitle.contains("too large"))
        #expect(
            summary.similarityDisplay == "similarity 20%",
            "overlap is closed form and stays reported")
    }

    @Test func aHeaderOnlyPoolHasNoChips() {
        #expect(
            datasetEstimateSummary(
                for: DatasetSpec(file: "cases.csv", sampleSize: 40),
                sourceCSV: "id,ward\n", divergenceMeasurable: true) == nil)
    }

    // MARK: - Number formatting

    @Test func percentTextRoundsByMagnitudeAndNeverClaimsZero() {
        #expect(estimatePercentText(1.0) == "100%")
        #expect(estimatePercentText(0.9996) == "100%")
        #expect(estimatePercentText(0.47) == "47%")
        #expect(estimatePercentText(0.078) == "7.8%")
        #expect(estimatePercentText(0.001) == "0.1%")
        #expect(estimatePercentText(0.0004) == "<0.1%")
    }

    @Test func unitsTextUsesTwoDecimalsAndAFloorMarker() {
        #expect(estimateUnitsText(0.037) == "0.04")
        #expect(estimateUnitsText(1.5) == "1.50")
        #expect(estimateUnitsText(0.004) == "<0.01")
        #expect(estimateUnitsText(0) == "<0.01")
    }
}
