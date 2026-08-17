// Core/DatasetDivergence.swift
//
// The measured half of the dataset diagnostics (overlap, the closed-form
// half, is in DatasetDiagnostics.swift).  Divergence answers "are students
// doing the same exercise?": per column, how far a student's slice sits from
// the instructor's pool, distributionally.
//
// It is measured, not derived — every sampled slice comes from
// `DatasetMaterializer.materialize`, the exact call delivery makes — so it
// covers every transform automatically, including kinds that do not exist
// yet.  A fairness report about bytes other than the delivered ones would be
// worse than no report.  The pool is parsed once and reused across seeds;
// the slices are never approximated.
//
// Two measures, deliberately not collapsed into one number: numeric columns
// get Wasserstein-1 in units of the pool's standard deviation ("SDs of
// transport"), categorical columns get total variation distance (already
// 0–1).  The two are not commensurable, and averaging across columns is
// banned by design — one catastrophically skewed column must not hide
// behind nineteen fine ones, so aggregation is max-and-name-the-column
// (`headlines(of:)`).

import Foundation

/// One column's measured divergence between student slices and the pool,
/// summarized over the preflight seeds.
public struct DatasetColumnDivergence: Sendable, Equatable, Codable {
    public enum Measure: String, Sendable, Equatable, Codable {
        /// Wasserstein-1 in units of the pool's standard deviation (numeric).
        case wasserstein
        /// Total variation distance, 0–1 (categorical).
        case totalVariation
    }

    public let column: String
    public let measure: Measure
    /// The median over the sampled seeds — a typical student.
    public let median: Double
    /// The maximum over the sampled seeds — an unlucky student.
    public let worst: Double
}

/// The per-measure headline: the worst column, by name.  `0.11` alone is not
/// actionable; `systolic 0.11 SD` is.  `Codable` because authoring surfaces
/// serve it to the Files panel as-is.
public struct DatasetDivergenceHeadline: Sendable, Equatable, Codable {
    public let measure: DatasetColumnDivergence.Measure
    public let column: String
    public let median: Double
    public let worst: Double
}

extension DatasetDiagnostics {

    /// How many deterministic preflight seeds `divergence` samples by
    /// default.  A constant, not configuration.
    public static let defaultSeedCount = 20

    /// The `index`-th preflight seed: a 64-hex string shaped like a real
    /// per-(student, assignment) seed, derived — never random — so the
    /// reported numbers cannot flicker between two computations over the same
    /// spec, and so any consumer fanning out over synthetic variants (the
    /// diagnostics here, multi-variant validation) exercises the same ones.
    public static func preflightSeed(_ index: Int) -> String {
        (0..<4).map { chunk in
            String(format: "%016llx", fnv1a64("preflight|\(index)|\(chunk)"))
        }.joined()
    }

    /// Per-column divergence between student slices and the pool, measured
    /// over `seedCount` preflight seeds via `DatasetMaterializer.materialize`.
    /// Columns are reported in header order.
    ///
    /// A column's distribution is that of its *observed* (non-empty) values:
    /// a `missingValues` hole is thinning, not a value, and the question this
    /// answers is whether the data a student sees looks like the pool —
    /// which MCAR blanking preserves by design (pinned by the MCAR test).  A
    /// column with nothing observed on either side contributes nothing.
    public static func divergence(
        spec: DatasetSpec, sourceCSV: String, seedCount: Int = defaultSeedCount
    ) -> [DatasetColumnDivergence] {
        guard seedCount > 0, let pool = ParsedColumns(csv: sourceCSV) else { return [] }

        var samples: [[Double]] = Array(repeating: [], count: pool.names.count)
        for seed in 0..<seedCount {
            let materialized = DatasetMaterializer.materialize(
                source: sourceCSV, spec: spec, seedHex: preflightSeed(seed))
            guard let slice = ParsedColumns(csv: materialized) else { continue }
            for index in pool.names.indices where index < slice.observed.count {
                let observed = slice.observed[index]
                guard !observed.isEmpty, !pool.observed[index].isEmpty else { continue }
                if let numbers = pool.numbers[index] {
                    let sliceNumbers = observed.compactMap(parseNumber)
                    guard !sliceNumbers.isEmpty else { continue }
                    let transport = wasserstein1(sliceNumbers, numbers)
                    let sd = pool.standardDeviation[index]
                    samples[index].append(sd > 0 ? transport / sd : 0)
                } else {
                    samples[index].append(totalVariation(observed, pool.observed[index]))
                }
            }
        }

        var results: [DatasetColumnDivergence] = []
        for index in pool.names.indices {
            let columnSamples = samples[index]
            guard !columnSamples.isEmpty else { continue }
            results.append(
                DatasetColumnDivergence(
                    column: pool.names[index],
                    measure: pool.numbers[index] != nil ? .wasserstein : .totalVariation,
                    median: median(of: columnSamples),
                    worst: columnSamples.max() ?? 0))
        }
        return results
    }

    /// The worst column per measure (ties to the earlier column), Wasserstein
    /// first.  Aggregating the two measures into one number would invent a
    /// comparison that does not exist, so there are up to two headlines.
    public static func headlines(of divergences: [DatasetColumnDivergence])
        -> [DatasetDivergenceHeadline]
    {
        [.wasserstein, .totalVariation].compactMap { measure in
            divergences
                .filter { $0.measure == measure }
                .max { $0.worst < $1.worst }
                .map {
                    DatasetDivergenceHeadline(
                        measure: measure, column: $0.column,
                        median: $0.median, worst: $0.worst)
                }
        }
    }

    // MARK: - Metrics

    /// Wasserstein-1 between two 1-D empirical distributions: the area
    /// between their quantile functions, computed exactly by walking both
    /// sorted samples with breakpoints compared in integer arithmetic (units
    /// of `1/(n·m)`), so the result is a pure function of the values.
    /// Internal so the metric itself can be pinned on hand-computable cases.
    static func wasserstein1(_ first: [Double], _ second: [Double]) -> Double {
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        let a = first.sorted()
        let b = second.sorted()
        let n = a.count
        let m = b.count
        var total = 0.0
        var i = 0
        var j = 0
        var position = 0  // consumed probability mass, in units of 1/(n·m)
        while i < n, j < m {
            let aEdge = (i + 1) * m
            let bEdge = (j + 1) * n
            let edge = min(aEdge, bEdge)
            total += abs(a[i] - b[j]) * Double(edge - position)
            position = edge
            if aEdge == edge { i += 1 }
            if bEdge == edge { j += 1 }
        }
        return total / Double(n * m)
    }

    /// Total variation distance between two categorical samples:
    /// `½ Σ |p̂(v) − q̂(v)|` over the union of observed values, summed in
    /// first-appearance order so the float sum is reproducible everywhere.
    static func totalVariation(_ first: [String], _ second: [String]) -> Double {
        guard !first.isEmpty, !second.isEmpty else { return 0 }
        var order: [String] = []
        var firstCounts: [String: Int] = [:]
        var secondCounts: [String: Int] = [:]
        for value in first {
            if firstCounts[value] == nil { order.append(value) }
            firstCounts[value, default: 0] += 1
        }
        for value in second {
            if firstCounts[value] == nil, secondCounts[value] == nil { order.append(value) }
            secondCounts[value, default: 0] += 1
        }
        let n = Double(first.count)
        let m = Double(second.count)
        var sum = 0.0
        for value in order {
            sum += abs(Double(firstCounts[value] ?? 0) / n - Double(secondCounts[value] ?? 0) / m)
        }
        return sum / 2
    }

    private static func median(of values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return (sorted[middle - 1] + sorted[middle]) / 2
        }
        return sorted[middle]
    }

    /// A finite number parsed from a CSV field, or nil.  Shared with
    /// `ParsedColumns.classify` so "is numeric" and "parse the slice" cannot
    /// disagree about what counts as a number.
    fileprivate static func parseNumber(_ raw: String) -> Double? {
        guard let value = Double(raw.trimmingCharacters(in: .whitespaces)), value.isFinite
        else { return nil }
        return value
    }
}

/// A parsed CSV, column-major: per column its observed (non-empty) raw
/// values in file order, plus — when every observed value parses as a finite
/// number — the parsed values and their population standard deviation.
/// Parsed once per pool and reused across every sampled seed; the slices
/// themselves always come from the real materializer.
private struct ParsedColumns {
    let names: [String]
    /// Non-empty raw values per column, file order.
    let observed: [[String]]
    /// Parsed values per column; nil marks a categorical column.
    let numbers: [[Double]?]
    /// Population standard deviation per column (0 for categorical).
    let standardDeviation: [Double]

    init?(csv: String) {
        let (lines, _) = DatasetMaterializer.normalizedLines(of: csv)
        guard lines.count > 1 else { return nil }
        let names = DatasetMaterializer.splitCSVLine(lines[0])
        guard !names.isEmpty else { return nil }

        var observed: [[String]] = Array(repeating: [], count: names.count)
        for index in 1..<lines.count {
            let fields = DatasetMaterializer.splitCSVLine(lines[index])
            for column in names.indices where column < fields.count {
                let value = fields[column]
                if !value.isEmpty { observed[column].append(value) }
            }
        }

        self.names = names
        self.observed = observed
        (numbers, standardDeviation) = Self.classify(observed)
    }

    /// A column is numeric when it has observed values and every one parses
    /// as a finite number; anything else — including a numeric-looking column
    /// with one "NA" — is categorical, where total variation is still a
    /// sound answer.
    private static func classify(_ observed: [[String]]) -> ([[Double]?], [Double]) {
        var numbers: [[Double]?] = []
        var deviations: [Double] = []
        for values in observed {
            let parsed = values.compactMap(DatasetDiagnostics.parseNumber)
            guard !parsed.isEmpty, parsed.count == values.count else {
                numbers.append(nil)
                deviations.append(0)
                continue
            }
            numbers.append(parsed)
            let mean = parsed.reduce(0, +) / Double(parsed.count)
            let squared = parsed.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            deviations.append((squared / Double(parsed.count)).squareRoot())
        }
        return (numbers, deviations)
    }
}
