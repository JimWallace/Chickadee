// Core/DatasetDiagnostics.swift
//
// Instructor-facing estimates about a per-student dataset spec: how many rows
// two students are expected to share (can they copy?), and — in
// DatasetDivergence.swift — how far one student's slice drifts from the pool
// (are they doing the same exercise?).  Both are read-only with respect to
// delivery: nothing here alters a delivered byte, and no seed is ever chosen
// or rejected to satisfy a diagnostic.
//
// The two halves have deliberately different dependency surfaces:
//
//   * Overlap is a function of SELECTION alone — a transform alters values
//     inside a student's rows and never changes which rows they hold (pinned
//     by `transformsNeverChangeTheRowSet` in DatasetDiagnosticsTests) — so it
//     is closed form, behind an exhaustive switch over `DatasetKind`.  A new
//     selection kind must answer here or this file does not compile.
//   * Divergence is MEASURED, via `DatasetMaterializer.materialize`, so it
//     covers every transform automatically, including ones not yet invented.
//
// The delivered-bytes determinism rules (`no Double`, no Dictionary
// iteration) do not bind here — these are statistics ABOUT bytes, not bytes —
// but the reported numbers still must not flicker between two computations
// over the same spec, so sums run in file order and seeds are derived, never
// random.

import Foundation

/// Closed-form estimate of how many rows two students' slices share.
/// `Codable` because authoring surfaces serve it to the Files panel as-is.
public struct DatasetOverlap: Sendable, Equatable, Codable {
    /// Data rows in the instructor's pool.
    public let poolRows: Int
    /// Rows one student receives.  Equal to `poolRows` when the spec does not
    /// reduce the file (no sample size, or one at least the pool's size).
    public let rowsPerStudent: Int
    /// Rows any two students are expected to share.
    public let expectedSharedRows: Double
    /// The fraction of ONE student's rows a peer is expected to also hold —
    /// `expectedSharedRows / rowsPerStudent`, the reference class an
    /// instructor thinks in.  Deliberately not Jaccard, whose union
    /// denominator is a set neither student holds and which shrinks as
    /// students diverge, understating copying risk.
    public let sharedFraction: Double
    /// Estimated shared rows for the *unluckiest* pair in a class of
    /// `classSize` — the pair the instructor hears from.  An extreme-value
    /// estimate over the class's C(C−1)/2 pairs, never below the mean and
    /// never above `rowsPerStudent`.
    public let worstPairSharedRows: Double
    /// The stratum whose rows are most shared, for a stratified sample.  The
    /// floor of one row per stratum makes a rare category the most copyable
    /// part of the assignment — every student draws from the same few pool
    /// rows — and that is invisible in the aggregate number, so it is
    /// reported by name.  Nil for a plain row sample (or a stratified spec
    /// that degrades to one).
    public let mostCopyableStratum: Stratum?

    /// Per-stratum overlap detail for `mostCopyableStratum`.
    public struct Stratum: Sendable, Equatable, Codable {
        /// The stratum column's value.
        public let value: String
        /// Pool rows carrying that value.
        public let poolRows: Int
        /// Rows of it each student receives (`apportion`'s allocation).
        public let rowsPerStudent: Int
        /// The fraction of one student's rows of this stratum a peer also
        /// holds (`rowsPerStudent / poolRows`).
        public let sharedFraction: Double
    }
}

/// Estimates about a per-student dataset spec, for authoring surfaces.
public enum DatasetDiagnostics {

    /// Class size the worst-pair estimate assumes when a caller has nothing
    /// better.  A constant, not configuration: the estimate moves with the
    /// *logarithm* of the pair count, so being off by even a factor of two
    /// barely moves the reported number.
    public static let defaultClassSize = 100

    /// Closed-form overlap for `spec` against the pool in `sourceCSV`, or nil
    /// when the pool has no data rows to speak about.
    ///
    /// Mirrors `DatasetMaterializer`'s envelope decisions exactly — the same
    /// line normalization, the same "keep everything" conditions, the same
    /// degradation of an unusable stratified spec to a plain sample, and the
    /// same `apportion` call for per-stratum allocations — so the estimate
    /// describes the bytes that actually ship.
    public static func overlap(
        spec: DatasetSpec, sourceCSV: String, classSize: Int = defaultClassSize
    ) -> DatasetOverlap? {
        let (lines, _) = DatasetMaterializer.normalizedLines(of: sourceCSV)
        guard lines.count > 1 else { return nil }
        let poolRows = lines.count - 1

        // The materializer keeps the whole file for a nil, non-positive, or
        // not-actually-reducing sample size; every student then holds every
        // row and the overlap is total.
        let requested = spec.sampleSize ?? poolRows
        let k = (requested > 0 && requested < poolRows) ? requested : poolRows

        switch spec.kind {
        case .rowSample:
            return plainOverlap(poolRows: poolRows, k: k, classSize: classSize)
        case .stratifiedSample:
            guard k < poolRows,
                let column = spec.stratumColumn, !column.isEmpty,
                let columnIndex = DatasetMaterializer.splitCSVLine(lines[0]).firstIndex(of: column)
            else {
                // Delivery degrades this spec to a plain row sample (or the
                // whole file); measure what ships, not what was asked for.
                return plainOverlap(poolRows: poolRows, k: k, classSize: classSize)
            }
            return stratifiedOverlap(
                lines: lines, poolRows: poolRows, k: k,
                columnIndex: columnIndex, classSize: classSize)
        }
    }

    /// Two independent size-`k` samples from a pool of `n` share a
    /// hypergeometric number of rows: mean `k²/n`, variance
    /// `k·(k/n)·(1−k/n)·(n−k)/(n−1)`.
    private static func plainOverlap(poolRows: Int, k: Int, classSize: Int) -> DatasetOverlap {
        let n = Double(poolRows)
        let kk = Double(k)
        let mean = kk * kk / n
        let variance = hypergeometricVariance(poolRows: poolRows, take: k)
        return DatasetOverlap(
            poolRows: poolRows,
            rowsPerStudent: k,
            expectedSharedRows: mean,
            sharedFraction: kk / n,
            worstPairSharedRows: worstPair(
                mean: mean, variance: variance, cap: kk, classSize: classSize),
            mostCopyableStratum: nil)
    }

    /// Under stratification the shared count is a sum of independent
    /// per-stratum hypergeometrics: mean `Σₛ kₛ²/Nₛ` with `kₛ` from the real
    /// `apportion` call — never the `k²/N` shortcut, which Titu's lemma makes
    /// a strict underestimate whenever allocation is non-proportional, and
    /// the one-row-per-stratum floor is non-proportional by construction.
    private static func stratifiedOverlap(
        lines: [Substring], poolRows: Int, k: Int, columnIndex: Int, classSize: Int
    ) -> DatasetOverlap {
        // Strata in order of first appearance, exactly as
        // `sampleStratifiedRows` builds them (a short row's missing value is
        // the "" category), so the allocation below is the delivered one.
        var strataOrder: [String] = []
        var sizesByStratum: [String: Int] = [:]
        for index in 1..<lines.count {
            let fields = DatasetMaterializer.splitCSVLine(lines[index])
            let value = columnIndex < fields.count ? fields[columnIndex] : ""
            if sizesByStratum[value] == nil { strataOrder.append(value) }
            sizesByStratum[value, default: 0] += 1
        }
        let sizes = strataOrder.map { sizesByStratum[$0] ?? 0 }
        let allocation = DatasetMaterializer.apportion(
            sampleSize: k, sizes: sizes, total: poolRows)

        var mean = 0.0
        var variance = 0.0
        var copyable: DatasetOverlap.Stratum?
        for (position, stratum) in strataOrder.enumerated() {
            let size = sizes[position]
            let take = min(allocation[position], size)
            guard take > 0, size > 0 else { continue }
            mean += Double(take) * Double(take) / Double(size)
            variance += hypergeometricVariance(poolRows: size, take: take)
            let fraction = Double(take) / Double(size)
            if fraction > (copyable?.sharedFraction ?? 0) {
                copyable = DatasetOverlap.Stratum(
                    value: stratum, poolRows: size, rowsPerStudent: take,
                    sharedFraction: fraction)
            }
        }
        return DatasetOverlap(
            poolRows: poolRows,
            rowsPerStudent: k,
            expectedSharedRows: mean,
            sharedFraction: mean / Double(k),
            worstPairSharedRows: worstPair(
                mean: mean, variance: variance, cap: Double(k), classSize: classSize),
            mostCopyableStratum: copyable)
    }

    /// Variance of the shared count between two independent size-`take`
    /// samples of a `poolRows` pool.  Zero for a single-row pool (the row is
    /// always shared) and for a whole-pool sample.
    private static func hypergeometricVariance(poolRows: Int, take: Int) -> Double {
        guard poolRows > 1 else { return 0 }
        let n = Double(poolRows)
        let kk = Double(take)
        return kk * (kk / n) * (1 - kk / n) * ((n - kk) / (n - 1))
    }

    /// Extreme-value estimate of the maximum shared count over a class's
    /// C(C−1)/2 pairs: `mean + σ·√(2·ln pairs)`, the standard Gumbel
    /// approximation for the max of many roughly-normal draws.  The pairs are
    /// not independent (each student appears in C−1 of them), so this is an
    /// estimate — clamped to `[mean, cap]` so it can never claim more shared
    /// rows than a student holds.
    private static func worstPair(
        mean: Double, variance: Double, cap: Double, classSize: Int
    ) -> Double {
        let pairs = classSize > 1 ? Double(classSize) * Double(classSize - 1) / 2 : 0
        guard pairs >= 2, variance > 0 else { return mean }
        return min(cap, mean + variance.squareRoot() * (2 * Foundation.log(pairs)).squareRoot())
    }
}
